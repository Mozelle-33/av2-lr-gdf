#!/usr/bin/env python3
"""Coverage of the luma LR by a set of LR stripe dumps (AVM_LR_DUMP or
tools/make_lr_stress.py): quantizer sets, classes (of 256), PC-Wiener filters
(of 64 per set) and Wiener-NS filter counts N that the checked units use.
Only the blocks of processing units with LR on count.

Usage: lr_coverage.py <label> <file.lrdump> [...]
"""
import sys
from collections import Counter
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lr_golden import (RESTORE_NONE, RESTORE_PC_WIENER, SUBCLS,  # noqa: E402
                       read_records)


def main(argv):
    label, paths = argv[0], argv[1:]
    cls_seen = np.zeros(256, bool)
    filt = np.zeros((4, 64), bool)             # PC-Wiener filters used, per set
    sub = {}                                   # (N, set) -> sub-classes used
    nvals = Counter()
    sets = Counter()
    units = Counter()
    for p in paths:
        for r in read_records(p):
            if r["has_lossless"] or r["skip_pcw"] or r["class_restrict"] >= 0:
                continue
            pw = r["procunit_width"]
            on = np.repeat(np.array(r["pu_type"][:r["n_pu"]]) != RESTORE_NONE, pw // 4)[:r["mi_cols"]]
            if not on.any():
                continue
            s, n = r["set_index"], r["num_classes"]
            pcw = r["rtype"] == RESTORE_PC_WIENER
            units["pcw" if pcw else "wns"] += int((np.array(r["pu_type"][:r["n_pu"]]) != RESTORE_NONE).sum())
            sets[s] += 1
            if not pcw:
                nvals[n] += 1
            if pcw or n > 1:
                c = r["cls"][:, on]
                cls_seen[np.unique(c)] = True
                if pcw:
                    filt[s][np.unique(SUBCLS[64][s][c])] = True
                else:
                    sub.setdefault((n, s), set()).update(int(v) for v in np.unique(SUBCLS[n][s][c]))
    print(f"== {label}: {len(paths)} dumps, processing units with LR on: {dict(units)}")
    print(f"classes seen: {int(cls_seen.sum())} of 256")
    print("quantizer sets (stripes): " + ", ".join(f"set {s}: {sets[s]}" for s in range(4)))
    print("PC-Wiener filters used per set: " + ", ".join(f"{int(filt[s].sum())}/64" for s in range(4)) +
          f"; any set: {int(filt.any(axis=0).sum())}/64; total {int(filt.sum())}/256")
    print("Wiener-NS stripes by N: " + ", ".join(f"N={n}: {nvals[n]}" for n in sorted(nvals)))
    full = sum(1 for (n, s), v in sub.items() if len(v) == n)
    print(f"Wiener-NS (N, set) pairs seen: {len(sub)} of 28, with all N sub-classes used: {full}")
    np.save(f"/root/work/tmp/lrcov_{label}.npy", np.concatenate([cls_seen, filt.ravel()]))


if __name__ == "__main__":
    main(sys.argv[1:])
