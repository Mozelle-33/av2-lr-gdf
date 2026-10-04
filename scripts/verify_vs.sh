#!/usr/bin/env bash
# Bit-exactness of the column-major core (VS = 1) against the row-major one.
# Usage: verify_vs.sh [real]
set -uo pipefail
cd /root/work
V=/root/work/vec
run() {  # label, env..., vec
  local label=$1; shift
  local vec=${@: -1}
  local envs=("${@:1:$#-1}")
  r=$(env "${envs[@]}" bash /mnt/g/AV2/scripts/sim.sh "$vec" 2>&1 | tail -1)
  echo "$label $(basename "$vec"): $r"
}
run "VS=1 FIP=0 MSTG=2" VS=1 FIP=0 MSTG=2 $V/stress_stripe.vec
run "VS=1 FIP=0 MSTG=1" VS=1 FIP=0 MSTG=1 $V/stress_stripe.vec
run "VS=1 FIP=1 MSTG=2" VS=1 FIP=1 MSTG=2 $V/stress_stripe_fip.vec
run "VS=1 FIP=1 MSTG=1" VS=1 FIP=1 MSTG=1 $V/stress_stripe_fip.vec
run "VS=0 FIP=1 MSTG=2" VS=0 FIP=1 MSTG=2 $V/stress_stripe_fip.vec
run "VS=1 IDXF=1"       VS=1 IDXF=1        $V/stress_stripe_idx.vec
run "VS=1 FULL=1"       VS=1 FULL=1        $V/stress_stripe_full.vec
if [ "${1:-}" = "real" ]; then
  run "VS=1 FIP=0 real" VS=1 FIP=0 $V/real_all.vec
  run "VS=1 FIP=1 real" VS=1 FIP=1 $V/real_all_fip.vec
  run "VS=0 FIP=0 real" VS=0 FIP=0 $V/real_all.vec
fi
echo VERIFY_VS_DONE
