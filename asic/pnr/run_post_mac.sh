#!/usr/bin/env bash
# Everything after run_pnr_mac.sh for a run with macros, in sequence: waits
# for the routed design, then the hold ECO at the typical and fast corners
# (pnr_mac_eco.tcl), the sign-off reports at the three corners
# (signoff_mac.sh) and the gate-level simulations and power windows
# (gl_joint_ch_r4.sh).
# Usage: [MACRO_DIR=dir] [MACRO_CORNERS=dir] run_post_mac.sh <tag>   (log: <run>/post.log)
set -uo pipefail
tag=$1
P=/mnt/g/AV2/asic/pnr
R=/root/work/pnr/$tag
export MACRO_DIR=${MACRO_DIR:-/root/work/macros_m4} MACRO_CORNERS=${MACRO_CORNERS:-/root/work/macros_corners}
L=$R/post.log
: > $L
while ! grep -q PNR_DONE $R/pnr.log 2>/dev/null; do
  pgrep -f "run_pnr_mac.sh $tag" > /dev/null || { grep -q PNR_DONE $R/pnr.log || { echo "P&R ended without PNR_DONE" | tee -a $L; exit 1; }; }
  sleep 60
done
cd $R
echo "== eco $(date +%T)" | tee -a $L
HOLD_ECO=0.03 OUT=$R SDC=$P/gdf_mac.sdc PERIOD=2.5 THREADS=24 \
  openroad -no_init -exit $P/pnr_mac_eco.tcl > $R/pnr_eco.log 2>&1
grep -E "^STAGE|_WNS|violations|ECO_DONE|PNR_DONE|Design area" $R/pnr_eco.log | tail -12 | tee -a $L
echo "== signoff $(date +%T)" | tee -a $L
bash $P/signoff_mac.sh $tag
tail -2 $R/signoff.log | tee -a $L
echo "== gate level and power $(date +%T)" | tee -a $L
GLJ=8 bash $P/gl_joint_ch_r4.sh $tag > $R/gl_joint_ch_r4.out 2>&1
tail -3 $R/gl_joint_ch_r4.log | tee -a $L
echo "POST_DONE $(date +%T)" | tee -a $L
