#!/usr/bin/env bash
# PC-Wiener classes (MSTG 1/2, FIP 0/1) and GDF outputs of the PCW=1 core,
# then the classifier-unit ASIC synthesis.
set -uo pipefail
cd /root/work
V=/root/work/vec
run() {
  local label=$1; shift
  local vec=${@: -1}
  local envs=("${@:1:$#-1}")
  r=$(env "${envs[@]}" bash /mnt/g/AV2/scripts/sim.sh "$vec" 2>&1 | tail -1)
  echo "$label $(basename "$vec"): $r"
}
run "PCW FIP=0 MSTG=2" VS=1 PCW=1 FIP=0 $V/pcw_all.vec
run "PCW FIP=1 MSTG=2" VS=1 PCW=1 FIP=1 $V/pcw_all.vec
run "PCW FIP=0 MSTG=1" VS=1 PCW=1 FIP=0 MSTG=1 $V/pcw_all.vec
run "PCW FIP=1 MSTG=1" VS=1 PCW=1 FIP=1 MSTG=1 $V/pcw_all.vec
run "PCW FIP=1 GDF stress" VS=1 PCW=1 FIP=1 $V/stress_stripe_fip.vec
run "PCW FIP=0 MSTG=1 GDF stress" VS=1 PCW=1 FIP=0 MSTG=1 $V/stress_stripe.vec
mkdir -p /root/work/asic/pcw_unit && cd /root/work/asic/pcw_unit && \
  /opt/yosys/bin/yosys -q -l yosys.log -s /mnt/g/AV2/asic/synth_pcw.ys > /dev/null 2>&1
grep -E 'Chip area|DFF_X1 ' /root/work/asic/pcw_unit/stat.txt
grep -h 'Delay =' /root/work/asic/pcw_unit/yosys.log | tail -1
echo VERIFY_PCW2_DONE
