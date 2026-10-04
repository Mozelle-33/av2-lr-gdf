#!/usr/bin/env python3
"""Bit-exact model of the AV2 PC-Wiener classifier (loop restoration, luma).

Reads the processing-unit records written by the instrumented AVM decoder
(AVM_PCW_DUMP, see avm/av2/common/tcas_instr.h) and recomputes the class of
every 4x4 block in two ways:
  direct : per-sample Laplacians summed over the 6x6 window (AVM order)
  cells  : 3x3 of GDF's odd-aligned 2x2 Laplacian cells (shared front end)
and compares both with the class ids of the decoder.

Usage: pcw_golden.py <file.pcwdump> [...]
"""
import re
import struct
import sys
from pathlib import Path

import numpy as np

AVM = Path(__file__).resolve().parents[1] / "avm" / "av2" / "common"
HDR_FIELDS = ("width", "height", "bit_depth", "tskip_zero", "classify_only", "qindex",
              "bv", "bh", "mi_rows", "mi_cols", "order_hint", "reserved")


def _c_array(text, name):
    m = re.search(name + r"\s*\[[^\]]*\]\s*=\s*\{(.*?)\};", text, re.S)
    return [int(x) for x in re.findall(r"-?\d+", m.group(1))]


_H = (AVM / "pc_wiener_filters.h").read_text()
LUT_TO_CLASS = np.array(_c_array(_H, "pc_wiener_lut_to_class_index"), np.int64)
assert LUT_TO_CLASS.size == 4096
THRESH = [512, 64, 8, 1]           # pc_wiener_thresholds
THRESH_SHIFT = 5                   # pc_wiener_threshold_shift
PREC_FEATURE = 14                  # PC_WIENER_PREC_FEATURE


def scale_luma(x):                 # SCALE_LUMA, 6x6 feature area
    return (x * 25 + 36 // 2) // 36


NORM = [scale_luma(0), scale_luma(5384), scale_luma(4713), scale_luma(4426)]
TSKIP_NORM = 256 // 36             # tskip_normalizer


def r2s(x, n):
    """ROUND_POWER_OF_TWO_SIGNED."""
    if n == 0:
        return x
    return -((-x + (1 << (n - 1))) >> n) if x < 0 else (x + (1 << (n - 1))) >> n


def read_records(path):
    data = Path(path).read_bytes()
    pos = 0
    while pos < len(data):
        assert data[pos:pos + 4] == b"PCWU", f"bad magic at {pos}"
        hdr = dict(zip(HDR_FIELDS, struct.unpack_from("<12i", data, pos + 4)))
        pos += 4 + 48
        h, w, bv, bh = hdr["height"], hdr["width"], hdr["bv"], hdr["bh"]
        mr, mc = hdr["mi_rows"], hdr["mi_cols"]
        n = (h + 2 * bv) * (w + 2 * bh)
        dgd = np.frombuffer(data, np.uint16, n, pos).reshape(h + 2 * bv, w + 2 * bh)
        pos += 2 * n
        tsk = np.frombuffer(data, np.uint8, mr * mc, pos).reshape(mr, mc)
        pos += mr * mc
        cls = np.frombuffer(data, np.uint8, mr * mc, pos).reshape(mr, mc)
        pos += mr * mc
        lut = np.frombuffer(data, np.int32, 1024, pos).reshape(256, 4)
        pos += 4096
        yield dict(hdr, dgd=dgd.astype(np.int64), tskip=tsk.astype(np.int64),
                   cls=cls.astype(np.int64), qval_lut=lut.astype(np.int64))


# absolute Laplacians of the three directions that the classifier uses
def laplacians(rec):
    """|vert|, |antiDiag|, |diag| at rows -2..h+1, cols -3..w+2 (AVM order f1..f3)."""
    s = rec["dgd"]
    bv, bh = rec["bv"], rec["bh"]
    c = s[1:-1, 1:-1]                       # rows -bv+1 .. h+bv-2
    up, dn = s[:-2, 1:-1], s[2:, 1:-1]
    ul, ur = s[:-2, :-2], s[:-2, 2:]
    dl, dr = s[2:, :-2], s[2:, 2:]
    vert = np.abs(up - 2 * c + dn)
    anti = np.abs(ur - 2 * c + dl)          # prev_row + 1, next_row - 1
    diag = np.abs(ul - 2 * c + dr)          # prev_row - 1, next_row + 1
    # index [r + bv - 1, x + bh - 1] is sample (r, x)
    return np.stack([vert, anti, diag]), bv - 1, bh - 1


# class of every 4x4 block: 6x6 Laplacian sums (directly, or as 3x3 of the
# 2x2 cells that the hardware shares with GDF), transform-skip count,
# normalisation, table Q, four 3-bit levels, class table
def classify(rec, via_cells=False):
    h, w, bd = rec["height"], rec["width"], rec["bit_depth"]
    lap, oy, ox = laplacians(rec)
    mr, mc = rec["mi_rows"], rec["mi_cols"]
    out = np.zeros((mr, mc), np.int64)
    tsk = rec["tskip"]
    for k in range(mr):
        for n in range(mc):
            i, j = 4 * k, 4 * n
            rows = [min(r, h + 1) for r in range(i - 1, i + 5)]   # AVM row clamp
            cols = [min(x, w + 1) for x in range(j - 1, j + 5)]   # AVM column clamp
            if via_cells:
                # 3x3 odd-aligned 2x2 cells: rows (i-1,i), (i+1,i+2), (i+3,i+4)
                acc = np.zeros(3, np.int64)
                for cr in range(3):
                    for cc in range(3):
                        rr = [rows[2 * cr], rows[2 * cr + 1]]
                        xx = [cols[2 * cc], cols[2 * cc + 1]]
                        for r in rr:
                            for x in xx:
                                acc += lap[:, r + oy, x + ox]
            else:
                acc = np.zeros(3, np.int64)
                for r in rows:
                    for x in cols:
                        acc += lap[:, r + oy, x + ox]
            fv = [0] + [int(acc[f]) * NORM[f + 1] for f in range(3)]
            if bd > 8:
                fv = [r2s(v, bd - 8) for v in fv]
            if rec["tskip_zero"]:
                ts = 0
            else:
                tr = [max(min(r, h - 1), 0) for r in range(i - 1, i + 5)]
                tc = [max(min(x, w - 1), 0) for x in range(j - 1, j + 5)]
                ts = sum(int(tsk[r >> 2, x >> 2]) for r in tr for x in tc) * TSKIP_NORM
            lut_in = 0
            for f in range(4):
                q = r2s(fv[f] + int(rec["qval_lut"][ts, f]), PREC_FEATURE)
                q = min(max(q, 0), 255) >> THRESH_SHIFT
                lut_in += THRESH[f] * q
            out[k, n] = LUT_TO_CLASS[lut_in]
    return out


def main(paths):
    units = blocks = bad_d = bad_c = 0
    hs = {}
    for p in paths:
        for rec in read_records(p):
            units += 1
            hs[rec["height"]] = hs.get(rec["height"], 0) + 1
            ref = rec["cls"]
            d = classify(rec)
            c = classify(rec, via_cells=True)
            blocks += ref.size
            bad_d += int((d != ref).sum())
            bad_c += int((c != ref).sum())
    print(f"units {units}, 4x4 blocks {blocks}, mismatches direct {bad_d}, cells {bad_c}")
    print("unit heights:", dict(sorted(hs.items())))
    return bad_d == 0 and bad_c == 0


if __name__ == "__main__":
    sys.exit(0 if main(sys.argv[1:]) else 1)
