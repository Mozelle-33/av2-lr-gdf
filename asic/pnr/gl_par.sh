#!/usr/bin/env bash
# Gate-level simulation of a routed gdf_core on K parts of a vector file in
# parallel (tools/split_vec.py: each part starts with the configuration state
# at its first segment); prints the summed tb_gdf summary.
# Usage: [BIN=model] gl_par.sh <tag> <file.vec> [K=12]
set -euo pipefail
tag=$1; vec=$2; k=${3:-12}
BIN=${BIN:-/root/work/pnr/$tag/gl/obj_t0/Vgdf_core}
[ -x $BIN ] || { echo "no model $BIN (build it with gl_sim.sh)"; exit 1; }
S=/root/work/pnr/glvec/split_$(basename $vec .vec)_$k
if [ ! -f $S/part_00.vec ] || [ $vec -nt $S/part_00.vec ]; then
  python3 /mnt/g/AV2/tools/split_vec.py $vec $k $S > $S.log
fi
for f in $S/part_*.vec; do
  GDF_VS=1 nice -n 5 $BIN $f > ${f%.vec}.$tag.out 2>&1 &
done
wait
# anything but the summary lines (errors, mismatches)
cat $S/part_*.$tag.out | grep -v '^segments' | head -20 || true
cat $S/part_*.$tag.out | grep '^segments' | awk -F', ' -v n=$(ls $S/part_*.vec | wc -l) '
  { for (i = 1; i <= NF; i++) { key = $i; sub(/ [0-9]+$/, "", key); v = $i; sub(/.* /, "", v);
      if (!(key in s)) k[++m] = key; s[key] += v } ; parts++ }
  END { if (parts != n) printf "ONLY %d OF %d PARTS FINISHED\n", parts, n;
        for (j = 1; j <= m; j++) printf "%s%s %d", (j > 1 ? ", " : ""), k[j], s[k[j]]; print "" }'
