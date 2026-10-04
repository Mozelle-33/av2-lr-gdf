"""Hardware-oriented analysis of the AV2 Guided Detail Filter (GDF) tables.

Reads the normative tables from the AV2 v1.0.0 specification attachments
(analysis/gdf_tables/*.h) and writes a report to analysis/results/.

Table layouts (spec section 7.20.5):
  Gdf_Weight[refDst 6][qp 6][out 3][feat 22][cls 4]
  Gdf_Alpha [refDst 6][qp 6][feat 22][cls 4]
  Gdf_Bias  [refDst 6][qp 6][out 3]
  Gdf_Intra_Error[qp 6][4096]         (16 x 16 x 16 index cube)
  Gdf_Inter_Error[refDst-1 5][qp 6][1000]   (10 x 10 x 10 index cube)
refDst 0 is intra; features 0..17 are neighbour-pair differences, 18..21 are
the four directional gradient sums (VER, HOR, DIAG0, DIAG1).
"""
import json
import math
import re
from collections import Counter
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent
TAB = ROOT / "gdf_tables"
OUT = ROOT / "results"

N_REF, N_QP, N_OUT, N_FEAT, N_CLS = 6, 6, 3, 22, 4
N_SPATIAL = 18

# Neighbour offsets (dy, dx) of the forward sample of each pair feature
# (Gdf_Coords in the spec; the backward sample is the point reflection).
COORDS = [(6, 0), (5, 0), (4, 0), (3, 0), (2, 1), (2, 0), (2, -1),
          (1, 2), (1, 1), (1, 0), (1, -1), (1, -2),
          (0, 6), (0, 5), (0, 4), (0, 3), (0, 2), (0, 1)]
FEAT_NAMES = [f"d({dy},{dx})" for dy, dx in COORDS] + ["gV", "gH", "gD0", "gD1"]

# Sub-filter support masks used by the AVM AVX2 implementation
# (gdf_guided_sample_{vertical,horizontal,mixed}_masks in gdf_block.c).
MASK_V = [1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0]
MASK_H = [0, 0, 0, 0, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0]
MASK_M = [0, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1]


def load(name, shape):
    body = (TAB / name).read_text().split("=", 1)[1]
    vals = [int(v) for v in re.findall(r"-?\d+", body)]
    assert len(vals) == math.prod(shape), (name, len(vals), shape)
    return np.array(vals, dtype=np.int64).reshape(shape)


def sbits(lo, hi):
    """Bits of a two's-complement word that holds every value in [lo, hi]."""
    b = 1
    while not (-(1 << (b - 1)) <= lo and hi <= (1 << (b - 1)) - 1):
        b += 1
    return b


def ubits(hi):
    return max(1, int(hi).bit_length())


def csd_digits(v):
    """Number of non-zero digits in the canonical signed-digit form of v."""
    v, n = abs(int(v)), 0
    while v:
        if v & 1:
            n += 1
            v = v - 1 if (v & 3) == 1 else v + 1
        v >>= 1
    return n


def entropy_bits(values):
    c = Counter(values.ravel().tolist())
    tot = sum(c.values())
    return -sum(n / tot * math.log2(n / tot) for n in c.values())


def main():
    OUT.mkdir(exist_ok=True)
    W = load("gdf_weight.h", (N_REF, N_QP, N_OUT, N_FEAT, N_CLS))
    A = load("gdf_alpha.h", (N_REF, N_QP, N_FEAT, N_CLS))
    B = load("gdf_bias.h", (N_REF, N_QP, N_OUT))
    E_intra = load("gdf_intra_error.h", (N_QP, 16, 16, 16))
    E_inter = load("gdf_inter_error.h", (N_REF - 1, N_QP, 10, 10, 10))

    rep, js = [], {}
    p = rep.append
    p("# AV2 GDF table analysis (spec v1.0.0 attachments)\n")

    # ------------------------------------------------------------------ weights
    p("## 1. Weights\n")
    nz = W != 0
    p(f"- entries: {W.size}, zero: {(~nz).sum()} ({(~nz).mean():.1%}), "
      f"range [{W.min()}, {W.max()}] -> {sbits(W.min(), W.max())}-bit signed")
    per_set = nz.sum(axis=(2, 3))  # (ref, qp, cls) after moving axes below
    per_set = nz.transpose(0, 1, 4, 2, 3).reshape(N_REF, N_QP, N_CLS, -1).sum(-1)
    p(f"- non-zero MACs per (refDst, qp, class): min {per_set.min()}, "
      f"max {per_set.max()}, mean {per_set.mean():.2f} (of {N_OUT * N_FEAT})")

    # Structural check: non-zero support vs. sub-filter masks with class swap.
    masks = {0: np.array(MASK_V, bool), 1: np.array(MASK_H, bool),
             2: np.array(MASK_M, bool)}
    violations, within_zero = 0, 0
    for r in range(N_REF):
        for q in range(N_QP):
            for c in range(N_CLS):
                odd = c & 1
                exp = {0: masks[1] if odd else masks[0],
                       1: masks[0] if odd else masks[1],
                       2: masks[2]}
                for o in range(N_OUT):
                    sup = nz[r, q, o, :, c]
                    violations += int((sup & ~exp[o]).sum())
                    within_zero += int((~sup & exp[o]).sum())
    total_mask = sum(int(m.sum()) for m in masks.values())
    p(f"- sub-filter masks: V={int(masks[0].sum())}, H={int(masks[1].sum())}, "
      f"M={int(masks[2].sum())} features (total {total_mask} MAC slots)")
    p(f"- weights outside the class-dependent masks (V/H swapped for odd "
      f"classes): **{violations}** non-zero entries")
    p(f"- zeros inside the masks: {within_zero} of "
      f"{N_REF * N_QP * N_CLS * total_mask} slots "
      f"({within_zero / (N_REF * N_QP * N_CLS * total_mask):.2%})")
    js["weight_mask_violations"] = violations

    # Per-slot weight ranges (slot = sub-filter x feature), folding the swap.
    slot_rows = []
    for name, o_even, o_odd, m in (("V", 0, 1, masks[0]), ("H", 1, 0, masks[1]),
                                    ("M", 2, 2, masks[2])):
        for k in np.flatnonzero(m):
            vals = np.concatenate([W[:, :, o_even, k, 0::2].ravel(),
                                   W[:, :, o_odd, k, 1::2].ravel()])
            slot_rows.append((name, int(k), FEAT_NAMES[k], int(vals.min()),
                              int(vals.max()), sbits(vals.min(), vals.max()),
                              max(csd_digits(v) for v in vals),
                              len(set(vals.tolist()))))
    p("\n| sub-filter | feat | offset | w min | w max | bits | max CSD digits | distinct |")
    p("|---|---|---|---|---|---|---|---|")
    for row in slot_rows:
        p("| " + " | ".join(str(x) for x in row) + " |")
    bits = [r[5] for r in slot_rows]
    p(f"\n- per-slot weight width: min {min(bits)}, max {max(bits)}, "
      f"sum {sum(bits)} bits over {len(bits)} slots "
      f"(uniform 10-bit would be {10 * len(bits)})")
    csd = Counter(csd_digits(v) for v in W[nz].ravel())
    p("- CSD non-zero digits of non-zero weights: " +
      ", ".join(f"{d}: {n} ({n / nz.sum():.1%})" for d, n in sorted(csd.items())))
    js["slot_weight_bits"] = bits

    # Class sharing
    p("\n### Class sharing\n")
    for c1, c2 in ((0, 2), (1, 3), (0, 1), (2, 3), (0, 3), (1, 2)):
        eq = (W[..., c1] == W[..., c2]).mean()
        eqa = (A[..., c1] == A[..., c2]).mean()
        p(f"- classes {c1}/{c2}: weights equal {eq:.1%}, alphas equal {eqa:.1%}")
    # exact duplicates across (ref, qp) sets
    sets = {}
    for r in range(N_REF):
        for q in range(N_QP):
            key = W[r, q].tobytes()
            sets.setdefault(key, []).append((r, q))
    p(f"- distinct weight sets over 36 (refDst, qp) combinations: {len(sets)}")

    # ------------------------------------------------------------------ alphas
    p("\n## 2. Clipping thresholds (alpha)\n")
    p(f"- range [{A.min()}, {A.max()}], distinct {len(np.unique(A))}, "
      f"=511 (no-op for spatial features after the ±512 clip): "
      f"{(A[:, :, :N_SPATIAL] == 511).mean():.1%} of spatial entries")
    sp, gr = A[:, :, :N_SPATIAL], A[:, :, N_SPATIAL:]
    p(f"- spatial alphas: [{sp.min()}, {sp.max()}]; gradient alphas: "
      f"[{gr.min()}, {gr.max()}]")

    # ------------------------------------------------------------------ bias
    p("\n## 3. Bias\n")
    p(f"- range [{B.min()}, {B.max()}] -> {sbits(B.min(), B.max())}-bit signed")

    # ------------------------------------------------------ accumulator width
    p("\n## 4. Datapath widths (worst case over all tables)\n")
    # spatial feature in [-512, 511]; gradient feature in [0, alpha] <= 511
    fmax = np.full(N_FEAT, 512)
    worst = 0
    for r in range(N_REF):
        for q in range(N_QP):
            for c in range(N_CLS):
                for o in range(N_OUT):
                    acc = int(np.abs(W[r, q, o, :, c]) @ fmax) + abs(int(B[r, q, o]))
                    worst = max(worst, acc)
    p(f"- feature operand: 10-bit signed (spatial), 9-bit unsigned (gradient)")
    p(f"- product: {sbits(-512 * 512, 512 * 512)}-bit signed")
    p(f"- worst-case |accumulator| bound {worst} -> {sbits(-worst, worst)}-bit signed")
    js["acc_bits"] = sbits(-worst, worst)

    # ---------------------------------------------------------- error tables
    p("\n## 5. Expected-error lookup tables\n")
    for name, E, lev in (("intra", E_intra, 16), ("inter", E_inter, 10)):
        flat = E.reshape(-1, lev ** 3)
        rng = (int(E.min()), int(E.max()))
        fixed = sbits(*rng)
        per_tab_bits = [sbits(int(t.min()), int(t.max())) for t in flat]
        ent = entropy_bits(E)
        # smoothness along the fastest index
        d = np.diff(E, axis=-1)
        p(f"- {name}: {flat.shape[0]} tables x {lev ** 3} entries, range {rng}, "
          f"distinct {len(np.unique(E))}, zeros {(E == 0).mean():.1%}")
        p(f"  - fixed width {fixed} bits -> {E.size * fixed / 8 / 1024:.1f} KiB; "
          f"per-table width {min(per_tab_bits)}..{max(per_tab_bits)} bits -> "
          f"{sum(b * lev ** 3 for b in per_tab_bits) / 8 / 1024:.1f} KiB")
        p(f"  - zeroth-order entropy {ent:.2f} bits/entry -> "
          f"{E.size * ent / 8 / 1024:.1f} KiB lower bound for symbol coding")
        p(f"  - |neighbour difference| <= 1 along last index: "
          f"{(np.abs(d) <= 1).mean():.1%}")
        # odd symmetry test e[i][j][k] == -e[mirror] on the symmetric sub-cube
        half = lev // 2
        sub = E[..., 1:, 1:, 1:] if lev % 2 == 0 else E
        mirror = sub[..., ::-1, ::-1, ::-1]
        p(f"  - odd symmetry e(x) == -e(-x) on symmetric sub-cube: "
          f"{(sub == -mirror).mean():.1%}; even symmetry: {(sub == mirror).mean():.1%}")
        js[f"err_{name}_fixed_bits"] = fixed

    # ------------------------------------------------------------- memory
    p("\n## 6. Storage summary (bits)\n")
    w_bits = W.size * sbits(W.min(), W.max())
    a_bits = A.size * ubits(A.max())
    b_bits = B.size * sbits(B.min(), B.max())
    e_bits = (E_intra.size * sbits(int(E_intra.min()), int(E_intra.max())) +
              E_inter.size * sbits(int(E_inter.min()), int(E_inter.max())))
    pruned_w = N_REF * N_QP * N_CLS * total_mask * sbits(W.min(), W.max())
    p(f"- weights {w_bits} (masked slots only: {pruned_w}), alpha {a_bits}, "
      f"bias {b_bits}, error tables {e_bits}")
    tot = w_bits + a_bits + b_bits + e_bits
    tot_pruned = pruned_w + a_bits + b_bits + e_bits
    p(f"- total {tot / 8 / 1024:.1f} KiB (with masked weights "
      f"{tot_pruned / 8 / 1024:.1f} KiB); ICIP 2025 proposal version: 259.9 kB")
    p(f"- per frame only one (refDst, qp) set is active: weights "
      f"{N_CLS * total_mask} x 10 b, alpha {N_FEAT * N_CLS} x 9 b, error table "
      f"<= 4096 x 7 b = {4096 * 7 / 8 / 1024:.1f} KiB")

    # -------------------------------------------------------- op counts
    p("\n## 7. Multiplications per luma sample\n")
    p("- spec as written: 3 x 22 = 66")
    p("- ICIP 2025 proposal (symmetric pairs, gradient shared per 2x2): 57")
    p(f"- mask-pruned: V 12 + H 12 + M 6 spatial = 30 per sample + "
      f"M 4 gradient per 2x2 block = {30 + 4 / 4:.0f} amortised")

    (OUT / "gdf_table_stats.md").write_text("\n".join(rep) + "\n", encoding="utf-8")
    (OUT / "gdf_table_stats.json").write_text(json.dumps(js, indent=2))
    print("\n".join(rep))


if __name__ == "__main__":
    main()
