#!/usr/bin/env bash
# Joint front end: PC-Wiener classes on all dumped processing units, and the
# GDF outputs of the same PCW=1 core (stress and real) for FIP 0/1.
set -uo pipefail
cd /root/work
V=/root/work/vec
[ -f $V/pcw_all.vec ] || python3 /mnt/g/AV2/tools/make_pcw_vectors.py $V/pcw_all.vec /root/work/dumps_pcw/*.pcwdump
run() {
  local label=$1; shift
  local vec=${@: -1}
  local envs=("${@:1:$#-1}")
  r=$(env "${envs[@]}" bash /mnt/g/AV2/scripts/sim.sh "$vec" 2>&1 | tail -1)
  echo "$label $(basename "$vec"): $r"
}
run "PCW FIP=0" VS=1 PCW=1 FIP=0 $V/pcw_all.vec
run "PCW FIP=1" VS=1 PCW=1 FIP=1 $V/pcw_all.vec
run "PCW FIP=0 MSTG=1" VS=1 PCW=1 FIP=0 MSTG=1 $V/pcw_all.vec
run "PCW FIP=0 GDF stress" VS=1 PCW=1 FIP=0 $V/stress_stripe.vec
run "PCW FIP=1 GDF stress" VS=1 PCW=1 FIP=1 $V/stress_stripe_fip.vec
run "PCW FIP=0 GDF real" VS=1 PCW=1 FIP=0 $V/real_all.vec
run "PCW FIP=1 GDF real" VS=1 PCW=1 FIP=1 $V/real_all_fip.vec
echo VERIFY_PCW_DONE
