#!/usr/bin/env bash
# Regression of the parameterised core: row-major ablation variants and the
# column-major core at 4, 8 and 16 samples per cycle (GC=2 / NB=1 / NB=2),
# with and without the fast inner product, on stress and real vectors.
# Usage: verify_scal.sh [real]
set -uo pipefail
MODE=${1:-}
ONLY_REAL=${ONLY_REAL:-0}
cd /root/work
V=/root/work/vec
run() {  # label, env..., vec
  local label=$1; shift
  local vec=${@: -1}
  local envs=("${@:1:$#-1}")
  r=$(env "${envs[@]}" bash /mnt/g/AV2/scripts/sim.sh "$vec" 2>&1 | tail -1)
  echo "$label $(basename "$vec"): $r"
}
if [ "$ONLY_REAL" != 1 ]; then
# row-major ablation (unchanged datapath, parameterised code)
run "V0 MACF=1 IDXF=1 LA=0" MACF=1 IDXF=1 LA=0 $V/stress_stripe_full.vec
run "V1 MACF=0 IDXF=1 LA=0" MACF=0 IDXF=1 LA=0 $V/stress_stripe_idx.vec
run "V2 MACF=0 IDXF=0 LA=0" MACF=0 IDXF=0 LA=0 $V/stress_stripe.vec
run "V3 row-major"          VS=0 $V/stress_stripe.vec
run "V3 row-major FIP"      VS=0 FIP=1 $V/stress_stripe_fip.vec
# column-major, 4 / 8 / 16 samples per cycle
for cfg in "GC=2 NB=1" "GC=4 NB=1" "GC=4 NB=2"; do
  set -- $cfg
  run "VS $cfg FIP=0 MSTG=2" VS=1 $1 $2 FIP=0 $V/stress_stripe.vec
  run "VS $cfg FIP=0 MSTG=1" VS=1 $1 $2 FIP=0 MSTG=1 $V/stress_stripe.vec
  run "VS $cfg FIP=1 MSTG=2" VS=1 $1 $2 FIP=1 $V/stress_stripe_fip.vec
done
fi
if [ "$MODE" = "real" ]; then
  run "V3 row-major real" VS=0 $V/real_all.vec
  for cfg in "GC=2 NB=1" "GC=4 NB=1" "GC=4 NB=2"; do
    set -- $cfg
    run "VS $cfg FIP=0 real" VS=1 $1 $2 FIP=0 $V/real_all.vec
    run "VS $cfg FIP=1 real" VS=1 $1 $2 FIP=1 $V/real_all_fip.vec
  done
fi
echo VERIFY_SCAL_DONE
