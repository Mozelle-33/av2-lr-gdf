#!/usr/bin/env bash
# Final regression of rtl/gdf_core.v: GDF (real units + stress units), the
# PC-Wiener classifier, the LR back end, the end-to-end joint stage and the
# chroma LR (CH = 1), for the ASIC (MSTG=1) and FPGA (MSTG=2) pipelines with
# and without the fast inner product.  Log: /root/work/verify_final.log
set -uo pipefail
V=/root/work/vec
L=/root/work/verify_final.log
: > $L
run() {  # label, env..., vec
  local label=$1; shift
  local vec=${@: -1}
  local envs=("${@:1:$#-1}")
  local r
  r=$(env "${envs[@]}" bash /mnt/g/AV2/scripts/sim.sh "$vec" 2>&1 | tail -1)
  echo "$label $(basename "$vec"): $r" | tee -a $L
}
# GDF cores: column scan (ASIC), column scan + FIP (FPGA), joint LR/GDF cores
run "VS m1"            VS=1 MSTG=1                    $V/real_all.vec
run "VS m1"            VS=1 MSTG=1                    $V/stress_stripe.vec
run "VS FIP m2"        VS=1 FIP=1 MSTG=2              $V/real_all_fip.vec
run "VS FIP m2"        VS=1 FIP=1 MSTG=2              $V/stress_stripe_fip.vec
run "JOINT m1"         VS=1 PCW=1 LR=1 MSTG=1         $V/real_all.vec
run "JOINT m1"         VS=1 PCW=1 LR=1 MSTG=1         $V/stress_stripe.vec
run "JOINT FIP m2"     VS=1 PCW=1 LR=1 FIP=1 MSTG=2   $V/real_all_fip.vec
run "JOINT FIP m2"     VS=1 PCW=1 LR=1 FIP=1 MSTG=2   $V/stress_stripe_fip.vec
# joint stage with the chroma LR, on the luma-only vectors (chroma off)
run "JOINT CH m1"      VS=1 PCW=1 LR=1 CH=1 MSTG=1         $V/real_all.vec
run "JOINT CH m1"      VS=1 PCW=1 LR=1 CH=1 MSTG=1         $V/stress_stripe.vec
run "JOINT CH FIP m2"  VS=1 PCW=1 LR=1 CH=1 FIP=1 MSTG=2   $V/real_all_fip.vec
run "JOINT CH FIP m2"  VS=1 PCW=1 LR=1 CH=1 FIP=1 MSTG=2   $V/stress_stripe_fip.vec
# PC-Wiener classifier (all processing units)
run "PCW m2"           VS=1 PCW=1 MSTG=2              $V/pcw_all.vec
run "PCW FIP m2"       VS=1 PCW=1 FIP=1 MSTG=2        $V/pcw_all.vec
run "PCW m1"           VS=1 PCW=1 MSTG=1              $V/pcw_all.vec
run "JOINT FIP m2"     VS=1 PCW=1 LR=1 FIP=1 MSTG=2   $V/pcw_all.vec
run "JOINT m1"         VS=1 PCW=1 LR=1 MSTG=1         $V/pcw_all.vec
# LR back end and end-to-end joint stage
bash /mnt/g/AV2/scripts/verify_lr_all.sh
for m in 1 2; do
  MSTG=$m bash /mnt/g/AV2/scripts/verify_lr_stripes.sh > /root/work/verify_lr_stripes_m$m.log 2>&1
  echo "LR stripes m$m: $(tail -1 /root/work/verify_lr_stripes_m$m.log)" | tee -a $L
done
grep -E '^==|PASS|FAIL' /root/work/verify_lr_all.log | tee -a $L
# chroma LR: every chroma stripe (regular streams and the down-sampling
# filters 0 and 2), and the joint units with the chroma of their region
bash /mnt/g/AV2/scripts/verify_lrc.sh > /root/work/verify_lrc.log 2>&1
echo "chroma stripes: $(tail -2 /root/work/verify_lrc.log | tr '\n' ' ')" | tee -a $L
DUMPS=/root/work/dumps_lrc_ds bash /mnt/g/AV2/scripts/verify_lrc.sh > /root/work/verify_lrc_ds.log 2>&1
echo "chroma stripes ds 0/2: $(tail -2 /root/work/verify_lrc_ds.log | tr '\n' ' ')" | tee -a $L
bash /mnt/g/AV2/scripts/verify_joint_ch.sh > /root/work/verify_joint_ch.log 2>&1
echo "joint + chroma: $(tail -1 /root/work/verify_joint_ch.log)" | tee -a $L
echo VERIFY_FINAL_DONE | tee -a $L
