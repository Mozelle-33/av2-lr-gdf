"""Summarise a set of GDF dumps: units, samples, bit depths, table sets."""
import sys

from gdf_dump import read_records

n = s = 0                               # units, samples
bds, sets, streams = set(), set(), 0    # bit depths, table sets (refDst, QP index), dump files
for p in sys.argv[1:]:
    streams += 1
    for r in read_records(p):           # one record per GDF unit
        n += 1
        s += r["h"] * r["w"]
        bds.add(r["bit_depth"])
        sets.add((r["ref_dst_idx"], r["qp_idx"]))
print(f"streams {streams}, units {n}, samples {s}, bit depths {sorted(bds)}, "
      f"table sets {len(sets)}: {sorted(sets)}")
