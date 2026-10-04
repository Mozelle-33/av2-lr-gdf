"""Fast inner product (Winograd 1968) for the GDF sub-filters, with the
feature products shared across the V, H and M supports.

  sum_k w_k f_k = sum_pairs (f_a + w_b)(f_b + w_a) - sum_pairs f_a f_b - sum_pairs w_a w_b

The feature term f_a f_b is shared by every sub-filter that uses the pair;
the weight term w_a w_b is a per-frame, per-class constant folded into a
class-dependent bias.  This script
  1. finds the minimum number of distinct feature pairs (exhaustive search),
  2. checks the identity exactly for all 36 table sets x 4 classes on random
     and extreme features, with 22-bit wrap-around arithmetic,
  3. reports operand and constant ranges.
"""
import itertools
import sys

import numpy as np

sys.path.insert(0, "/mnt/g/AV2/analysis")
from gdf_golden import Tables  # noqa: E402
from gdf_hw_model import FrameParams, H_FEATS, M_FEATS, V_FEATS  # noqa: E402

V = list(V_FEATS)
H = list(H_FEATS)
M = [k for k in M_FEATS if k < 18]            # spatial part of M


def matchings(items):
    if not items:
        yield []
        return
    a = items[0]
    for i in range(1, len(items)):
        rest = items[1:i] + items[i + 1:]
        for m in matchings(rest):
            yield [(a, items[i])] + m


def min_union():
    best = None
    mv = [frozenset(frozenset(p) for p in m) for m in matchings(V)]
    mh = [frozenset(frozenset(p) for p in m) for m in matchings(H)]
    mm = [frozenset(frozenset(p) for p in m) for m in matchings(M)]
    # V and H share at most 3 pairs; restrict to matchings sharing pairs inside V&H
    for pm in mm:
        for pv in mv:
            if best is not None and len(pv | pm) >= best[0]:
                continue
            for ph in mh:
                u = len(pv | ph | pm)
                if best is None or u < best[0]:
                    best = (u, pv, ph, pm)
    return best


def wrap(x, bits=22):
    x = np.asarray(x, dtype=np.int64) & ((1 << bits) - 1)
    return np.where(x >= 1 << (bits - 1), x - (1 << bits), x)


def main():
    PV = [(5, 9), (16, 17), (8, 10), (0, 1), (2, 3), (4, 6)]
    PH = [(5, 9), (16, 17), (8, 10), (7, 11), (12, 13), (14, 15)]
    PM = [(5, 9), (16, 17), (3, 15)]
    shared = sorted(set(PV) | set(PH) | set(PM))
    print("pairs V", PV, "\npairs H", PH, "\npairs M", PM)
    print("distinct feature products:", len(shared), "; mixed products:",
          len(PV) + len(PH) + len(PM), "; total per sample:",
          len(shared) + len(PV) + len(PH) + len(PM), "(direct: 30)")
    if "--search" in sys.argv:
        u = min_union()
        print("exhaustive minimum of distinct pairs:", u[0])

    T = Tables()
    rng = np.random.default_rng(1)
    n = 20000
    f = rng.integers(-512, 512, size=(n, 18))
    f[:64] = np.array([[-512] * 18, [511] * 18] * 32)          # extremes
    maxmix = maxk = 0
    for r in range(6):
        for q in range(6):
            fp = FrameParams(T, r, q)
            for c in range(4):
                for name, feats, w, pairs in (("V", V, fp.wv[c], PV), ("H", H, fp.wh[c], PH),
                                              ("M", M, fp.wm[c][:len(M)], PM)):
                    wk = dict(zip(feats, w))
                    direct = sum(int(wk[k]) * f[:, k] for k in feats)
                    mixed = sum((f[:, a] + wk[b]) * (f[:, b] + wk[a]) for a, b in pairs)
                    ff = sum(f[:, a] * f[:, b] for a, b in pairs)
                    kw = sum(int(wk[a]) * int(wk[b]) for a, b in pairs)
                    fip = wrap(wrap(mixed) - wrap(ff) - kw)
                    assert np.array_equal(fip, wrap(direct)), (r, q, c, name)
                    assert np.abs(direct).max() < 1 << 21
                    maxmix = max(maxmix, int(np.abs(np.array([f[:, a] + wk[b] for a, b in pairs])).max()))
                    maxk = max(maxk, abs(kw))
    print("identity exact for 36 sets x 4 classes x 3 sub-filters x", n, "feature vectors")
    print("max |f + w| =", maxmix, "(11-bit signed);  max |weight term| =", maxk)


if __name__ == "__main__":
    main()
