"""Worst-case word-length (interval) analysis of the normalised GDF datapath.

All bounds are exact worst cases over every table set and class of the AV2
v1.0.0 tables, for the 10-bit-normalised datapath (R9 in gdf_hw_model.py).
Writes results/gdf_wordlength.md.
"""
from pathlib import Path

import numpy as np

from gdf_hw_model import H_FEATS, M_FEATS, V_FEATS
from gdf_table_stats import N_SPATIAL, load, sbits

# normative tables, indexed [refDst, QP index, ...]: weights [output, feature,
# class], clipping thresholds [feature, class], biases [output]
W = load("gdf_weight.h", (6, 6, 3, 22, 4))
A = load("gdf_alpha.h", (6, 6, 22, 4))
B = load("gdf_bias.h", (6, 6, 3))

rows = []


# one node of the datapath: its range and its width (signed if lo < 0)
def row(node, lo, hi, note=""):
    bits = sbits(lo, hi) if lo < 0 else max(1, int(hi).bit_length())
    kind = "s" if lo < 0 else "u"
    rows.append((node, lo, hi, f"{bits}{kind}", note))


# features, from the sample range of the normalised datapath
SMAX = 1023
row("input sample (normalised)", 0, SMAX, "8-bit input << 2")
row("difference s_n - s_c", -SMAX, SMAX)
row("clipped difference", -511, 511, "alpha in [1, 511]")
row("pair sum", -1022, 1022)
row("spatial feature f_k (saturated)", -512, 511)
row("Laplacian |2b-a-c|", 0, 2 * SMAX)
row("2x2 cell sum", 0, 8 * SMAX)
row("4x4 box sum", 0, 32 * SMAX)
row("gradient feature min(box>>4, alpha)", 0, 511)

# products per array: the sub-filters V and H feed outputs 0 and 1 (swapped
# for odd classes), M feeds output 2 (R1 in gdf_hw_model.py); spatial features
# are signed 10 bit, gradient features 0..511
for name, feats, outs in (("V", V_FEATS, (0, 1)), ("H", H_FEATS, (0, 1)), ("M", M_FEATS, (2,))):
    wsp = [W[:, :, o, k, :] for o in outs for k in feats if k < N_SPATIAL]
    wgr = [W[:, :, o, k, :] for o in outs for k in feats if k >= N_SPATIAL]
    if wsp:
        lo = min(int(x.min()) for x in wsp)
        hi = max(int(x.max()) for x in wsp)
        row(f"{name}: spatial weight", lo, hi)
        prods = [a * b for a in (-512, 511) for b in (lo, hi)]
        row(f"{name}: spatial product f*w", min(prods), max(prods))
    if wgr:
        lo = min(int(x.min()) for x in wgr)
        hi = max(int(x.max()) for x in wgr)
        row(f"{name}: gradient weight", lo, hi)
        row(f"{name}: gradient product g*w", 511 * lo, 511 * hi)

# accumulators incl. bias, exact worst case over sets, classes and routing
acc = {"V": 0, "H": 0, "M": 0}
for r in range(6):
    for q in range(6):
        for c in range(4):
            odd = c & 1
            ov, oh = (1, 0) if odd else (0, 1)
            wv = np.abs(W[r, q, ov, V_FEATS, c]).sum() * 512 + abs(int(B[r, q, ov]))
            wh = np.abs(W[r, q, oh, H_FEATS, c]).sum() * 512 + abs(int(B[r, q, oh]))
            wm = sum(abs(int(W[r, q, 2, k, c])) * (512 if k < N_SPATIAL else int(min(511, A[r, q, k, c])))
                     for k in M_FEATS) + abs(int(B[r, q, 2]))
            acc["V"] = max(acc["V"], int(wv))
            acc["H"] = max(acc["H"], int(wh))
            acc["M"] = max(acc["M"], int(wm))
for k, v in acc.items():
    row(f"{k}: accumulator (incl. bias)", -v, v, "exact over all 144 set/class pairs")
# quantized indices, table address, expected error and correction
row("LUT index per output", 0, 15, "4 bits; inter uses 0..9")
row("LUT address {d0,d1,d2}", 0, 4095, "12 bits, R6")
row("expected error e", -53, 42, "intra -53..42, inter -23..15")
row("e * s_pic (s_pic <= 4)", -212, 168)
row("correction after Round2Signed", -53, 42, "shift 4 (8-bit) / 2 (10-bit)")

# report (Markdown)
md = ["# GDF datapath word lengths (worst case, 10-bit normalised datapath)\n",
      "| node | min | max | bits | note |", "|---|---|---|---|---|"]
md += [f"| {n} | {lo} | {hi} | {b} | {note} |" for n, lo, hi, b, note in rows]
out = Path(__file__).resolve().parent / "results" / "gdf_wordlength.md"
out.write_text("\n".join(md) + "\n", encoding="utf-8")
print("\n".join(md))
