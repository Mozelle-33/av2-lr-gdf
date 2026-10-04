"""Functional-coverage report of GDF test vectors (for golden model / RTL).

Usage: python3 gdf_coverage.py <dump1> [dump2 ...]
Counts how often each corner case of the datapath is exercised:
feature saturation, alpha clipping, index clipping at both ends, output
clamping, every class, every table set, every bit depth, LUT entries hit.
"""
import sys
from collections import Counter
from pathlib import Path

import numpy as np

from gdf_dump import read_records
from gdf_golden import APRON, Tables, gdf_unit_err, round2signed
from gdf_table_stats import COORDS, N_SPATIAL


def main(paths):
    T = Tables()
    cov = Counter()                 # corner case -> samples (or units) that hit it
    lut_hit = {}                    # table set -> entries of the error table read
    n = 0
    for p in paths:
        for rec in read_records(p):
            if rec["has_lossless"]:
                continue            # units with lossless blocks are not test vectors
            h, w = rec["h"], rec["w"]
            q, r, bd = rec["qp_idx"], rec["ref_dst_idx"], rec["bit_depth"]
            # golden model with its intermediate values: class of every 2x2
            # block, accumulators of the three outputs, table addresses
            err, dbg = gdf_unit_err(rec["win"], h, w, q, r, bd, T, return_debug=True)
            n += h * w
            cov[f"bitdepth {bd}"] += 1
            cov[f"table set r{r} q{q}"] += 1
            cov[f"unit {h}x{w}"] += 1
            for c in range(4):
                cov[f"class {c}"] += int((dbg["cls"] == c).sum())
            # the spatial features again without the clips: differences of the
            # two samples at -+(dy, dx) to the center sample, at 10-bit scale,
            # clipped at the alpha of the class; their sum saturates to 10 bits
            s = rec["win"].astype(np.int64)
            ctr = s[APRON:APRON + h, APRON:APRON + w]
            clsf = np.repeat(np.repeat(dbg["cls"], 2, 0), 2, 1)
            shift = 10 - min(10, bd)
            for k in range(N_SPATIAL):
                dy, dx = COORDS[k]
                a = T.A[r, q, k][clsf]
                d3 = (s[APRON - dy:APRON - dy + h, APRON - dx:APRON - dx + w] - ctr) << shift
                d4 = (s[APRON + dy:APRON + dy + h, APRON + dx:APRON + dx + w] - ctr) << shift
                c3 = np.clip(d3, -a, a)
                c4 = np.clip(d4, -a, a)
                cov["alpha clip active"] += int(((c3 != d3) | (c4 != d4)).sum())
                cov["feature sat +511"] += int((c3 + c4 > 511).sum())
                cov["feature sat -512"] += int((c3 + c4 < -512).sum())
            # index of an output: Round2Signed(acc * scale, 15) clipped to
            # -scale..scale-1, 16 levels with the intra tables (refDst 0) and 10
            # with the inter tables
            scale = 8 if r == 0 else 5
            for o in range(3):
                v = round2signed((dbg["acc"][o] + T.B[r, q, o]) * scale, 15)
                cov[f"index clip low  out{o}"] += int((v < -scale).sum())
                cov[f"index clip high out{o}"] += int((v > scale - 1).sum())
            # compensation: the scaled error added to the LR output, clamped to
            # the sample range
            corr = round2signed(err.astype(np.int64) * rec["scale_val"], 12 - bd)
            pre = rec["lr"].astype(np.int64) + corr
            cov["output clamp at 0"] += int((pre < 0).sum())
            cov["output clamp at max"] += int((pre > (1 << bd) - 1).sum())
            key = (r, q)
            lut_hit.setdefault(key, set()).update(np.unique(dbg["pos"]).tolist())
    print(f"samples: {n}")
    for k in sorted(cov):
        print(f"  {k:28s} {cov[k]}")
    # an intra table has 16^3 entries, an inter table 10^3
    tot_entries = sum(4096 if r == 0 else 1000 for (r, q) in lut_hit)
    hit = sum(len(v) for v in lut_hit.values())
    print(f"  LUT entries hit: {hit} of {tot_entries} in {len(lut_hit)} table sets")


if __name__ == "__main__":
    main([Path(p) for p in sys.argv[1:]])
