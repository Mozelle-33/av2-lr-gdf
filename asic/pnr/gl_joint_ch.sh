#!/usr/bin/env bash
# Post-layout checks of the routed joint stage with the chroma LR (CH = 1):
# gate-level simulation of the luma vectors of gl_joint.sh (joint units,
# Wiener-NS units, segments across restoration units, the 3,000 GDF stress
# units in 12 parallel parts), joint units with chroma (type 7: the same 40
# KristenAndSara 720p units, 24 of them with chroma) and chroma stripes
# (type 6: BlueSky 360p with the cross-component down-sampling filters 0 and
# 2, RollerCoaster 720p 10-bit); then the switching activity of 20,000 cycles
# of the back-to-back joint units with chroma (segment 2 + 20 cycles, the
# window of the luma-only estimate) and the OpenSTA power with the extracted
# parasitics.  One traced model serves all runs (it traces only when GDF_VCD
# is set).
# Usage: [GLJ=8] gl_joint_ch.sh <tag>      (log: /root/work/pnr/<tag>/gl_joint_ch.log)
set -uo pipefail
tag=$1
ROOT=/mnt/g/AV2
P=$ROOT/asic/pnr
R=/root/work/pnr/$tag
G=/root/work/pnr/glvec
L=$R/gl_joint_ch.log
: > $L
export TRACE=1 GLJ=${GLJ:-8}
# chroma vectors (MSTG = 1, no FIP)
KS=KristenAndSara_1280x720_60_ai_q110_s2_f2
[ -f $G/joint_ch_ks40.vec ] || python3 $ROOT/tools/make_joint_vectors.py $G/joint_ch_ks40.vec \
  /root/work/dumps_lr/$KS.gdfdump /root/work/dumps_lr/$KS.lrdump --lrc /root/work/dumps_lrc/$KS.lrcdump \
  --max 40 | tee -a $L
[ -f $G/joint_ch_ks40_w.vec ] || python3 $ROOT/tools/dedup_writes.py $G/joint_ch_ks40.vec $G/joint_ch_ks40_w.vec | tee -a $L
for d in /root/work/dumps_lrc_ds/BlueSky_360p25_v2_ai_q110_ds0 /root/work/dumps_lrc_ds/BlueSky_360p25_v2_ai_q110_ds2 \
         /root/work/dumps_lrc/RollerCoaster_1280x720p_5994_10bit_420_ai_q110_s2_f2; do
  v=$G/lrc_$(basename $d).vec
  [ -f $v ] || python3 $ROOT/tools/make_lrc_vectors.py $v $d.lrcdump | tee -a $L
done
for v in $G/joint_ks40.vec $G/lr_st40.vec $G/stripes10.vec $G/joint_ch_ks40.vec \
         $G/lrc_BlueSky_360p25_v2_ai_q110_ds0.vec $G/lrc_BlueSky_360p25_v2_ai_q110_ds2.vec \
         $G/lrc_RollerCoaster_1280x720p_5994_10bit_420_ai_q110_s2_f2.vec; do
  echo "== $(basename $v) $(date +%T)" | tee -a $L
  bash $P/gl_sim.sh $tag $v 2>&1 | tail -1 | tee -a $L
done
[ -x $R/gl/obj_t1/Vgdf_core ] || { echo "no model" | tee -a $L; exit 1; }
echo "== stress_stripe.vec, 12 parts $(date +%T)" | tee -a $L
BIN=$R/gl/obj_t1/Vgdf_core bash $P/gl_par.sh $tag /root/work/vec/stress_stripe.vec 12 > $R/gl/stress.log 2>&1 &
spid=$!
# switching activity: 20,000 cycles of the back-to-back units from segment 2 + 20
echo "== trace $(date +%T)" | tee -a $L
GDF_VCD=$R/gl/ksch_b2b20k.vcd GDF_VCD_SEG=2 GDF_VCD_SKIP=20 GDF_VCD_LEN=20000 \
  bash $P/gl_sim.sh $tag $G/joint_ch_ks40_w.vec 2>&1 | tail -1 | tee -a $L
python3 $P/vcd_to_pins.py $R/final.v /root/work/pnr/orfs/flow/platforms/nangate45/lib/NangateOpenCellLibrary_typical.lib \
  $R/gl/ksch_b2b20k.vcd $R/gl/ksch_b2b20k_pins.vcd TOP.gdf_core.u_pnr 2>&1 | tee -a $L
rm -f $R/gl/ksch_b2b20k.vcd
cd $R
# placement colored by function, with the instance labels for the power split
LABELS=$R/labels.txt python3 $P/layout_by_function.py $R \
  /root/work/pnr/orfs/flow/platforms/nangate45/lef/NangateOpenCellLibrary.macro.mod.lef \
  $R/layout_func.png $R/area_func.csv 2>&1 | tee -a $L
OUT=$R SDC=$P/gdf.sdc PERIOD=2.5 VCD=$R/gl/ksch_b2b20k_pins.vcd SCOPE=TOP/gdf_core/u_pnr RPT=power_vcd_ch20k.rpt \
  INST_RPT=power_inst_ch20k.rpt openroad -no_init -exit $P/power_vcd.tcl > $R/power_vcd_ch20k.log 2>&1
grep -E "annotated|Annotated|^Total|^Sequential|^Combinational|^Clock|POWER_VCD_DONE" $R/power_vcd_ch20k.log | tee -a $L
python3 $P/power_by_function.py $R/power_inst_ch20k.rpt $R/labels.txt $R/power_func.csv 2>&1 | tee -a $L
wait $spid
echo "== stress result $(date +%T)" | tee -a $L
tail -3 $R/gl/stress.log | tee -a $L
echo GL_JOINT_CH_DONE | tee -a $L
