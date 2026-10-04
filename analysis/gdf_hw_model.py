"""Hardware-oriented, bit-exact reformulation of the AV2 GDF unit process.

Every transformation below must reproduce gdf_golden.gdf_unit_err /
gdf_compensate exactly; `verify` checks this on dumps and stress vectors.

R1  Sub-filter decomposition.  Non-zero weights only occur on three fixed
    supports V (12 features), H (12), M (10); for odd classes V and H swap
    roles.  34 MAC slots instead of 66, fixed input wiring, 2x2 swap network.
R2  Block-shared gradient MACs.  The 4 gradient terms of sub-filter M are
    identical for the 4 samples of a 2x2 block: 30 MACs/sample + 4/block.
R4  Separable box sums.  Per-sample Laplacians -> 2x2 cell sums (cells start
    at odd offsets) -> each 4x4 box is the sum of 2x2 cells.  Class and the 4
    gradient features come from the same box sums.
R5  Multiplier-free index quantisation.
      intra: Round2Signed(8*x, 15) == Round2Signed(x, 12)
      inter: Round2Signed(5*x, 15), 5*x = (x << 2) + x
R6  Unified 12-bit LUT addressing.  Inter tables (10x10x10) are re-laid into
    the intra 16x16x16 address space, so address = {d0, d1, d2} (4 bits each)
    for both frame types: no address arithmetic, one 4096-entry table memory.
R7  Bias folding.  The accumulator is preloaded with the per-output bias.
R8  Multiplier-free compensation.  err * s_pic with s_pic in 1..4 is a
    shift-add ((e << 1) + e for 3).
R9  Input normalisation.  8-bit samples are shifted left by 2 once at the
    input; the core then always works on 10-bit samples with shift 0.  The
    36 difference shifters and 4 gradient shifters of the spec disappear;
    class decisions are scale invariant, box sums scale linearly.
"""
import sys
from pathlib import Path

import numpy as np

from gdf_dump import read_records
from gdf_golden import APRON, DIRS, Tables, gdf_compensate, gdf_unit_err, round2signed
from gdf_table_stats import COORDS, MASK_H, MASK_M, MASK_V, N_SPATIAL

V_FEATS = [k for k in range(22) if MASK_V[k]]
H_FEATS = [k for k in range(22) if MASK_H[k]]
M_FEATS = [k for k in range(22) if MASK_M[k]]
M_SPATIAL = [k for k in M_FEATS if k < N_SPATIAL]
M_GRAD = [k for k in M_FEATS if k >= N_SPATIAL]


class FrameParams:
    """Per-frame register file: what the hardware loads once per frame."""

    def __init__(self, T, ref_dst_idx, qp_idx):
        W = T.W[ref_dst_idx, qp_idx]  # (3, 22, 4)
        self.alpha = T.A[ref_dst_idx, qp_idx]  # (22, 4)
        self.bias = T.B[ref_dst_idx, qp_idx]  # (3,)
        self.intra = ref_dst_idx == 0
        # R1: per class, weights already routed to the physical V/H/M MAC arrays
        self.wv = np.zeros((4, len(V_FEATS)), np.int64)
        self.wh = np.zeros((4, len(H_FEATS)), np.int64)
        self.wm = np.zeros((4, len(M_FEATS)), np.int64)
        for c in range(4):
            ov, oh = (1, 0) if c & 1 else (0, 1)
            self.wv[c] = W[ov, V_FEATS, c]
            self.wh[c] = W[oh, H_FEATS, c]
            self.wm[c] = W[2, M_FEATS, c]
        # R6: one 4096-entry table image, address = d0<<8 | d1<<4 | d2
        self.lut = np.zeros(4096, np.int64)
        if self.intra:
            self.lut[:] = T.E_intra[qp_idx]
        else:
            e = T.E_inter[ref_dst_idx - 1][qp_idx].reshape(10, 10, 10)
            self.lut.reshape(16, 16, 16)[:10, :10, :10] = e


def cell_sums(win, h, w):
    """R4: 2x2 cell sums of the 4 Laplacians; cells cover rows 2m-1..2m."""
    s = win.astype(np.int64)
    o = APRON - 1
    lap = np.zeros((4, h + 2, w + 2), np.int64)
    for d, (dy, dx) in DIRS.items():
        b = s[o:o + h + 2, o:o + w + 2]
        a = s[o - dy:o - dy + h + 2, o - dx:o - dx + w + 2]
        c = s[o + dy:o + dy + h + 2, o + dx:o + dx + w + 2]
        lap[d] = np.abs(2 * b - a - c)
    # (h/2 + 1) x (w/2 + 1) cells: cell (m, n) = lap rows 2m..2m+1 of the
    # (h+2) region, i.e. sample rows 2m-1..2m of the unit.
    cells = lap[:, 0::2, 0::2] + lap[:, 1::2, 0::2] + lap[:, 0::2, 1::2] + lap[:, 1::2, 1::2]
    return cells  # shape (4, h/2+1, w/2+1)


def box_from_cells(cells):
    """4x4 box of 2x2 block (m, n) = cells (m..m+1, n..n+1)."""
    return cells[:, :-1, :-1] + cells[:, 1:, :-1] + cells[:, :-1, 1:] + cells[:, 1:, 1:]


def hw_unit_err(win, h, w, qp_idx, ref_dst_idx, bit_depth, T, fp=None):
    fp = fp or FrameParams(T, ref_dst_idx, qp_idx)
    # R9: normalise once at the input; everything below is 10-bit, shift 0
    s = win.astype(np.int64) << (10 - min(10, bit_depth))
    shift = 0
    box = box_from_cells(cell_sums(s, h, w))  # (4, h/2, w/2)
    # class: 2 comparators per 2x2 block
    cls_blk = (box[0] <= box[1]).astype(np.int64) | ((box[2] <= box[3]).astype(np.int64) << 1)
    up = lambda a: np.repeat(np.repeat(a, 2, 0), 2, 1)
    cls = up(cls_blk)
    center = s[APRON:APRON + h, APRON:APRON + w]

    def spatial_feature(k):
        dy, dx = COORDS[k]
        a = fp.alpha[k][cls]
        d3 = (s[APRON - dy:APRON - dy + h, APRON - dx:APRON - dx + w] - center) << shift
        d4 = (s[APRON + dy:APRON + dy + h, APRON + dx:APRON + dx + w] - center) << shift
        return np.clip(np.clip(d3, -a, a) + np.clip(d4, -a, a), -512, 511)

    feat = {k: spatial_feature(k) for k in range(N_SPATIAL)}
    # R1/R7: three physical MAC arrays, accumulators preloaded with bias
    sv = sum(feat[k] * fp.wv[cls, i] for i, k in enumerate(V_FEATS))
    sh = sum(feat[k] * fp.wh[cls, i] for i, k in enumerate(H_FEATS))
    sm = sum(feat[k] * fp.wm[cls, i] for i, k in enumerate(M_FEATS) if k < N_SPATIAL)
    # R2: gradient MACs once per 2x2 block, then broadcast
    gblk = np.zeros_like(box[0])
    for i, k in enumerate(M_FEATS):
        if k >= N_SPATIAL:
            d = k - N_SPATIAL
            a = fp.alpha[k][cls_blk]
            g = np.minimum(box[d] >> 4, a)
            gblk += g * fp.wm[cls_blk, i]
    sm = sm + up(gblk)
    odd = (cls & 1).astype(bool)
    acc0 = np.where(odd, sh, sv) + fp.bias[0]
    acc1 = np.where(odd, sv, sh) + fp.bias[1]
    acc2 = sm + fp.bias[2]
    # R5: multiplier-free quantisation; R6: concatenated address
    if fp.intra:
        q = lambda x: np.clip(round2signed(x, 12), -8, 7) + 8
    else:
        q = lambda x: np.clip(round2signed((x << 2) + x, 15), -5, 4) + 5
    addr = (q(acc0) << 8) | (q(acc1) << 4) | q(acc2)
    return fp.lut[addr]


def hw_compensate(lr, err, scale_val, bit_depth):
    e = err.astype(np.int64)
    prod = {1: e, 2: e << 1, 3: (e << 1) + e, 4: e << 2}[scale_val]  # R8
    corr = round2signed(prod, 12 - bit_depth)
    return np.clip(lr.astype(np.int64) + corr, 0, (1 << bit_depth) - 1)


def verify(paths):
    T = Tables()
    cache = {}
    n = bad = 0
    for p in paths:
        for rec in read_records(p):
            if rec["has_lossless"]:
                continue
            key = (rec["ref_dst_idx"], rec["qp_idx"])
            fp = cache.get(key) or cache.setdefault(key, FrameParams(T, *key))
            h, w = rec["h"], rec["w"]
            ref = gdf_unit_err(rec["win"], h, w, rec["qp_idx"], rec["ref_dst_idx"],
                               rec["bit_depth"], T)
            hw = hw_unit_err(rec["win"], h, w, rec["qp_idx"], rec["ref_dst_idx"],
                             rec["bit_depth"], T, fp)
            out = hw_compensate(rec["lr"], hw, rec["scale_val"], rec["bit_depth"])
            n += 1
            if not (np.array_equal(ref, hw) and np.array_equal(ref, rec["err"])
                    and np.array_equal(out, rec["out"])):
                bad += 1
                if bad <= 5:
                    print(f"MISMATCH {p} unit ({rec['i_min']},{rec['j_min']})")
    print(f"hw model vs golden vs AVM: units {n}, mismatches {bad}")
    return bad == 0


if __name__ == "__main__":
    sys.exit(0 if verify([Path(p) for p in sys.argv[1:]]) else 1)
