"""Check that LR's pixel-classified Wiener (PC-Wiener) box features can be
built from GDF's 2x2 cell sums (shared classification front-end).

PC-Wiener (spec 7.20.4): for the 4x4 block at (x, y), f1/f2/f3 are the sums of
|vert|, |antiDiag|, |diag| over dy, dx in [-1, 4] (6x6 box).  GDF uses the
same per-sample Laplacians (V, D1, D0) on the same source samples.  Its 2x2
cells cover rows/cols 2m-1..2m, so the 6x6 box of block (4p, 4q) is exactly
the 3x3 cells m = 2p..2p+2, n = 2q..2q+2.  (PC-Wiener clamps x at
BlockEndX + 2, which only matters at the right picture edge; skipped here.)

Usage: python3 gdf_lr_sharing.py <dump> [...]
"""
import sys
from pathlib import Path

import numpy as np

from gdf_dump import read_records
from gdf_hw_model import cell_sums


def pcw_direct(win, h, w, apron):
    """Raw-scale PC-Wiener box features f1..f3 of every 4x4 block of the unit."""
    s = win.astype(np.int64)
    out = np.zeros((3, h // 4, w // 4), np.int64)
    for p in range(h // 4):
        for q in range(w // 4):
            y0, x0 = apron + 4 * p, apron + 4 * q
            acc = np.zeros(3, np.int64)
            for dy in range(-1, 5):
                for dx in range(-1, 5):
                    y, x = y0 + dy, x0 + dx
                    m = s[y, x]
                    vert = s[y - 1, x] - 2 * m + s[y + 1, x]
                    anti = s[y - 1, x + 1] - 2 * m + s[y + 1, x - 1]
                    diag = s[y - 1, x - 1] - 2 * m + s[y + 1, x + 1]
                    acc += (abs(vert), abs(anti), abs(diag))
            out[:, p, q] = acc
    return out


def pcw_from_cells(win, h, w):
    cells = cell_sums(win, h, w)  # (4 dirs: V, H, D0, D1), (h/2+1, w/2+1)
    sel = np.stack([cells[0], cells[3], cells[2]])  # vert, antiDiag, diag
    out = np.zeros((3, h // 4, w // 4), np.int64)
    for i in range(3):
        for j in range(3):
            out += sel[:, i:i + h // 2 - 1:2, j:j + w // 2 - 1:2][:, :h // 4, :w // 4]
    return out


def main(paths):
    blocks = bad = 0
    for p in paths:
        for rec in read_records(p):
            h, w = rec["h"], rec["w"]
            if h % 4 or w % 4:
                continue
            a = pcw_direct(rec["win"], h, w, rec["apron"])
            b = pcw_from_cells(rec["win"], h, w)
            blocks += a.shape[1] * a.shape[2]
            bad += int((a != b).any(axis=0).sum())
    print(f"PC-Wiener 4x4 blocks checked: {blocks}, mismatches: {bad}")
    return bad == 0


if __name__ == "__main__":
    sys.exit(0 if main([Path(p) for p in sys.argv[1:]]) else 1)
