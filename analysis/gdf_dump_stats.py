"""Data-driven GDF statistics from instrumented-decoder dumps.

Usage: python3 gdf_dump_stats.py <out.md> <dump1> [dump2 ...]
Uses the golden model's intermediate values (class, features, accumulators,
LUT positions) to characterise real AV2 content:
  * class distribution, table-set usage (intra/inter, refDst, qp)
  * how often each clipping threshold is active
  * real accumulator range vs. the worst-case bound
  * LUT address concentration (how many distinct entries a frame touches)
  * how many samples the filter actually modifies
"""
import sys
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np

from gdf_dump import read_records
from gdf_golden import APRON, Tables, gdf_compensate, gdf_unit_err
from gdf_table_stats import COORDS, FEAT_NAMES, N_SPATIAL


def main(out_md, paths):
    T = Tables()
    cls_cnt = Counter()                 # class -> samples
    set_cnt = Counter()                 # table set (refDst, QP index) -> samples
    clip_act = np.zeros(22)             # per feature: samples with an active clip
    feat_n = 0
    acc_min = np.full(3, np.iinfo(np.int64).max)    # accumulator range of the three outputs
    acc_max = np.full(3, np.iinfo(np.int64).min)
    err_zero = err_n = changed = 0
    frame_pos = defaultdict(Counter)    # (stream, frame) -> table address -> accesses
    units = 0
    for p in paths:
        for rec in read_records(p):
            if rec["has_lossless"]:
                continue
            h, w = rec["h"], rec["w"]
            q, r, bd = rec["qp_idx"], rec["ref_dst_idx"], rec["bit_depth"]
            err, dbg = gdf_unit_err(rec["win"], h, w, q, r, bd, T, return_debug=True)
            units += 1
            cls = dbg["cls"]                # one class per 2x2 block
            for c in range(4):
                cls_cnt[c] += int((cls == c).sum()) * 4
            set_cnt[(r, q)] += h * w
            # clipping activity: recompute raw (unclipped) spatial terms
            s = rec["win"].astype(np.int64)
            ctr = s[APRON:APRON + h, APRON:APRON + w]
            clsf = np.repeat(np.repeat(cls, 2, 0), 2, 1)
            shift = 10 - min(10, bd)
            for k in range(N_SPATIAL):
                dy, dx = COORDS[k]
                alpha = T.A[r, q, k][clsf]
                d3 = (s[APRON - dy:APRON - dy + h, APRON - dx:APRON - dx + w] - ctr) << shift
                d4 = (s[APRON + dy:APRON + dy + h, APRON + dx:APRON + dx + w] - ctr) << shift
                clip_act[k] += int(((np.abs(d3) > alpha) | (np.abs(d4) > alpha)).sum())
            # gradient features: min(box sum >> 4, alpha), clipped where they
            # reach alpha
            for k in range(N_SPATIAL, 22):
                alpha = T.A[r, q, k][clsf]
                clip_act[k] += int((dbg["feats"][k] >= alpha).sum())
            feat_n += h * w
            acc = dbg["acc"]
            acc_min = np.minimum(acc_min, acc.reshape(3, -1).min(1))
            acc_max = np.maximum(acc_max, acc.reshape(3, -1).max(1))
            err_zero += int((err == 0).sum())
            err_n += err.size
            # samples that the filter changes after scaling and rounding
            out = gdf_compensate(rec["lr"], err, rec["scale_val"], bd)
            changed += int((out != rec["lr"]).sum())
            key = (Path(p).name, rec["frame_idx"])
            frame_pos[key].update(dbg["pos"].ravel().tolist())

    # report (Markdown)
    L = [f"# GDF statistics on decoded AV2 content\n",
         f"- units: {units}, samples: {err_n}"]
    tot = sum(cls_cnt.values())
    L.append("- class distribution: " + ", ".join(
        f"{c}: {100 * cls_cnt[c] / tot:.1f}%" for c in range(4)))
    L.append("- table sets used (refDst, qp): " + ", ".join(
        f"{k}: {100 * v / err_n:.1f}%" for k, v in sorted(set_cnt.items())))
    L.append(f"- expected error == 0: {100 * err_zero / err_n:.1f}% of samples; "
             f"output differs from LR output: {100 * changed / err_n:.1f}%")
    L.append("- accumulator range observed: " + ", ".join(
        f"out{o}: [{acc_min[o]}, {acc_max[o]}]" for o in range(3)))
    L.append("\n| feature | clipping active |\n|---|---|")
    for k in range(22):
        L.append(f"| {FEAT_NAMES[k]} | {100 * clip_act[k] / feat_n:.2f}% |")
    # concentration of the table accesses of a frame: distinct entries, and
    # the share of the accesses that go to the 64 most used ones
    distinct = [len(c) for c in frame_pos.values()]
    cover = []
    for c in frame_pos.values():
        n = sum(c.values())
        top = sorted(c.values(), reverse=True)
        cover.append(sum(top[:64]) / n)
    L.append(f"\n- LUT entries touched per frame: min {min(distinct)}, "
             f"median {int(np.median(distinct))}, max {max(distinct)}")
    L.append(f"- share of accesses hitting the 64 most used entries: "
             f"median {100 * np.median(cover):.1f}%")
    Path(out_md).write_text("\n".join(L) + "\n", encoding="utf-8")
    print("\n".join(L))


if __name__ == "__main__":
    main(sys.argv[1], [Path(p) for p in sys.argv[2:]])
