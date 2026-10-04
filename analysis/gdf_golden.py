"""Bit-exact golden model of the AV2 Guided Detail Filter (spec v1.0.0, 7.20.5).

The model works on one GDF processing unit at a time, exactly the granularity
of the hardware core: an h x w block of luma samples (h, w <= 64, even) plus a
6-sample apron on every side, taken from the guided frame (the frame before
loop restoration, with AVM's stripe-boundary substitution already applied).

  err = gdf_unit_err(win, ...)       expected coding error (before scaling)
  out = gdf_compensate(lr, err, ...) final samples = LR output + scaled error

Validation against AVM dumps:  python3 gdf_golden.py <dump.bin> [...]
"""
import sys
from pathlib import Path

import numpy as np

from gdf_dump import read_records
from gdf_table_stats import COORDS, N_FEAT, N_SPATIAL, load

GDF_VER, GDF_HOR, GDF_DIAG0, GDF_DIAG1 = range(4)
DIRS = {GDF_VER: (1, 0), GDF_HOR: (0, 1), GDF_DIAG0: (1, 1), GDF_DIAG1: (-1, 1)}  # (dy, dx)
APRON = 6


class Tables:
    def __init__(self):
        self.W = load("gdf_weight.h", (6, 6, 3, N_FEAT, 4))
        self.A = load("gdf_alpha.h", (6, 6, N_FEAT, 4))
        self.B = load("gdf_bias.h", (6, 6, 3))
        self.E_intra = load("gdf_intra_error.h", (6, 4096))
        self.E_inter = load("gdf_inter_error.h", (5, 6, 1000))


def round2signed(x, n):
    if n == 0:
        return x
    half = 1 << (n - 1)
    return np.where(x >= 0, (x + half) >> n, -((-x + half) >> n))


# Laplacians of the four directions around every sample of the unit
def gradients(win, h, w):
    """grad[d][i][j] for the (h+2) x (w+2) region around the unit (spec)."""
    g = np.zeros((4, h + 2, w + 2), dtype=np.int64)
    s = win.astype(np.int64)
    o = APRON - 1  # window row/col of unit position -1
    for d, (dy, dx) in DIRS.items():
        b = s[o:o + h + 2, o:o + w + 2]
        a = s[o - dy:o - dy + h + 2, o - dx:o - dx + w + 2]
        c = s[o + dy:o + dy + h + 2, o + dx:o + dx + w + 2]
        g[d] = np.abs(2 * b - a - c)
    return g


# box sums over the 4x4 window of every 2x2 block
def grad_sums(g, h, w):
    """4x4 sums of grad for each 2x2 block: shape (4, h/2, w/2)."""
    hb, wb = h // 2, w // 2
    out = np.zeros((4, hb, wb), dtype=np.int64)
    for di in range(4):
        for dj in range(4):
            out += g[:, di:di + 2 * hb:2, dj:dj + 2 * wb:2]
    return out


# expected error of every sample of a unit: class, features, three linear
# models, index quantisation, table lookup (as gdf_inference_unit of AVM)
def gdf_unit_err(win, h, w, qp_idx, ref_dst_idx, bit_depth, T, return_debug=False):
    """Expected coding error for every sample of the unit (int array h x w)."""
    s = win.astype(np.int64)
    pxl_shift = 10 - min(10, bit_depth)
    g = gradients(win, h, w)
    st = grad_sums(g, h, w)
    cls_blk = ((st[GDF_VER] > st[GDF_HOR]) == 0).astype(np.int64) | \
              (((st[GDF_DIAG0] > st[GDF_DIAG1]) == 0).astype(np.int64) << 1)
    cls = np.repeat(np.repeat(cls_blk, 2, axis=0), 2, axis=1)  # (h, w)

    W = T.W[ref_dst_idx, qp_idx]  # (3, 22, 4)
    A = T.A[ref_dst_idx, qp_idx]  # (22, 4)
    Bv = T.B[ref_dst_idx, qp_idx]  # (3,)
    center = s[APRON:APRON + h, APRON:APRON + w]

    feats = np.zeros((N_FEAT, h, w), dtype=np.int64)
    for k in range(N_FEAT):
        alpha = A[k][cls]
        if k < N_SPATIAL:
            dy, dx = COORDS[k]
            s3 = s[APRON - dy:APRON - dy + h, APRON - dx:APRON - dx + w]
            s4 = s[APRON + dy:APRON + dy + h, APRON + dx:APRON + dx + w]
            above = np.clip((s3 - center) << pxl_shift, -alpha, alpha)
            below = np.clip((s4 - center) << pxl_shift, -alpha, alpha)
            feats[k] = np.clip(above + below, -512, 511)
        else:
            d = k - N_SPATIAL
            v = (st[d] << pxl_shift) >> 4
            v = np.repeat(np.repeat(v, 2, axis=0), 2, axis=1)
            feats[k] = np.minimum(v, alpha)

    intra = ref_dst_idx == 0
    scale = 8 if intra else 5
    acc = np.zeros((3, h, w), dtype=np.int64)
    for o in range(3):
        for k in range(N_FEAT):
            acc[o] += feats[k] * W[o, k][cls]
    pos = np.zeros((h, w), dtype=np.int64)
    for o in range(3):
        v = round2signed((acc[o] + Bv[o]) * scale, 15)
        pos = pos * scale * 2 + np.clip(v, -scale, scale - 1) + scale
    if intra:
        err = T.E_intra[qp_idx][pos]
    else:
        err = T.E_inter[ref_dst_idx - 1][qp_idx][pos]
    if return_debug:
        return err, dict(cls=cls_blk, feats=feats, acc=acc, pos=pos)
    return err


# correction added to the LR output and clipped to the bit depth
def gdf_compensate(lr, err, scale_val, bit_depth):
    corr = round2signed(err.astype(np.int64) * scale_val, 12 - bit_depth)
    return np.clip(lr.astype(np.int64) + corr, 0, (1 << bit_depth) - 1)


def verify(paths, max_mismatch_print=5):
    T = Tables()
    n = n_err_bad = n_out_bad = 0
    for path in paths:
        for rec in read_records(path):
            if rec["has_lossless"]:
                continue
            h, w = rec["h"], rec["w"]
            err = gdf_unit_err(rec["win"], h, w, rec["qp_idx"], rec["ref_dst_idx"],
                               rec["bit_depth"], T)
            out = gdf_compensate(rec["lr"], err, rec["scale_val"], rec["bit_depth"])
            n += 1
            bad_e = not np.array_equal(err, rec["err"])
            bad_o = not np.array_equal(out, rec["out"])
            n_err_bad += bad_e
            n_out_bad += bad_o
            if (bad_e or bad_o) and n_err_bad + n_out_bad <= max_mismatch_print:
                d = np.argwhere(err != rec["err"])
                print(f"mismatch {path} frame {rec['frame_idx']} unit "
                      f"({rec['i_min']},{rec['j_min']}) {h}x{w}: err diffs {len(d)}, "
                      f"first {d[:3].tolist()}")
    print(f"units checked: {n}, err mismatches: {n_err_bad}, output mismatches: {n_out_bad}")
    return n_err_bad == 0 and n_out_bad == 0


if __name__ == "__main__":
    ok = verify([Path(p) for p in sys.argv[1:]])
    sys.exit(0 if ok else 1)
