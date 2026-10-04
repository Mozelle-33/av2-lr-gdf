#!/usr/bin/env bash
# Post-layout checks of the routed joint LR/GDF core: gate-level simulation of
# joint units (LR + GDF, 720p intra), Wiener-NS LR units, segments across
# restoration units and the 3,000 GDF stress units (12 parts in parallel,
# gl_par.sh); meanwhile the switching activity of 3,000 cycles of the joint
# units (VCD) and the OpenSTA power with the extracted parasitics.  One traced
# model serves all runs (it traces only when GDF_VCD is set).
# Usage: [GLJ=8] gl_joint.sh <tag>      (log: /root/work/pnr/<tag>/gl_joint.log)
set -uo pipefail
tag=$1
P=/mnt/g/AV2/asic/pnr
R=/root/work/pnr/$tag
G=/root/work/pnr/glvec
L=$R/gl_joint.log
: > $L
export TRACE=1 GLJ=${GLJ:-8}
for v in $G/joint_ks40.vec $G/lr_st40.vec $G/stripes10.vec; do
  echo "== $(basename $v) $(date +%T)" | tee -a $L
  bash $P/gl_sim.sh $tag $v 2>&1 | tail -2 | tee -a $L
done
[ -x $R/gl/obj_t1/Vgdf_core ] || { echo "no model" | tee -a $L; exit 1; }
echo "== stress_stripe.vec, 12 parts $(date +%T)" | tee -a $L
BIN=$R/gl/obj_t1/Vgdf_core bash $P/gl_par.sh $tag /root/work/vec/stress_stripe.vec 12 > $R/gl/stress.log 2>&1 &
spid=$!
# switching activity: segment 2 of the joint units, 3,000 cycles from cycle 20
echo "== trace $(date +%T)" | tee -a $L
GDF_VCD=$R/gl/ks.vcd GDF_VCD_SEG=2 GDF_VCD_SKIP=20 GDF_VCD_LEN=3000 \
  bash $P/gl_sim.sh $tag $G/joint_ks40.vec 2>&1 | tail -2 | tee -a $L
python3 $P/vcd_to_pins.py $R/final.v /root/work/pnr/orfs/flow/platforms/nangate45/lib/NangateOpenCellLibrary_typical.lib \
  $R/gl/ks.vcd $R/gl/ks_pins.vcd TOP.gdf_core.u_pnr 2>&1 | tee -a $L
cd $R
OUT=$R SDC=$P/gdf.sdc PERIOD=2.5 VCD=$R/gl/ks_pins.vcd SCOPE=TOP/gdf_core/u_pnr \
  openroad -no_init -exit $P/power_vcd.tcl > $R/power_vcd.log 2>&1
grep -E "annotated|Annotated|^Total|^Sequential|^Combinational|^Clock|POWER_VCD_DONE" $R/power_vcd.log | tee -a $L
wait $spid
echo "== stress result $(date +%T)" | tee -a $L
tail -3 $R/gl/stress.log | tee -a $L
echo GL_JOINT_DONE | tee -a $L
