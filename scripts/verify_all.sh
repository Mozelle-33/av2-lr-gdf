#!/usr/bin/env bash
# Bit-exactness regression of all gdf_core variants (FULL x MSTG).
cd /root/work
V=/root/work/vec
for f in 0 1; do for m in 2 1; do
  sfx=""; [ $f = 1 ] && sfx="_full"
  r=$(FULL=$f MSTG=$m bash /mnt/g/AV2/scripts/sim.sh $V/stress_stripe$sfx.vec 2>&1 | tail -1)
  echo "FULL=$f MSTG=$m stress: $r"
  if [ "${1:-}" = "real" ]; then
    r=$(FULL=$f MSTG=$m bash /mnt/g/AV2/scripts/sim.sh $V/real_all$sfx.vec 2>&1 | tail -1)
    echo "FULL=$f MSTG=$m real:   $r"
  fi
done; done
