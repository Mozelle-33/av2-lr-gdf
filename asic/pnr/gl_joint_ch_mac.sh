#!/usr/bin/env bash
# Post-layout checks of the routed joint stage with its SRAM macros
# (pnr_mac.tcl), as gl_joint_ch.sh for the logic-only layout: gate-level
# simulation (gl_sim_mac.sh: netlist + macro models) of the luma vectors
# (joint units, Wiener-NS units, segments across restoration units, the 3,000
# GDF stress units in 12 parallel parts), the joint units with chroma, the
# chroma stripes (three down-sampling filters, 10-bit) and the chroma segments
# over several restoration units (glvec_multi); then the switching activity
# of the 20,000-cycle windows of the 720p and 4K intra frames and the OpenSTA
# power with the extracted parasitics and the macro models, split by function.
# Usage: [GLJ=8] gl_joint_ch_mac.sh <tag>      (log: /root/work/pnr/<tag>/gl_joint_ch.log)
set -uo pipefail
tag=$1
ROOT=/mnt/g/AV2
P=$ROOT/asic/pnr
R=/root/work/pnr/$tag
G=/root/work/pnr/glvec
M=${MACRO_DIR:-/root/work/macros}
export MACRO_DIR=$M
PLAT=/root/work/pnr/orfs/flow/platforms/nangate45
LIBS=$PLAT/lib/NangateOpenCellLibrary_typical.lib,$(ls $M/*/*.lib | tr '\n' ',' | sed 's/,$//')
LEFS=$PLAT/lef/NangateOpenCellLibrary.macro.mod.lef,$(ls $M/*/*.lef | tr '\n' ',' | sed 's/,$//')
L=$R/gl_joint_ch.log
: > $L
export TRACE=1 GLJ=${GLJ:-8}
for v in $G/joint_ks40.vec $G/lr_st40.vec $G/stripes10.vec $G/joint_ch_ks40.vec \
         $G/lrc_BlueSky_360p25_v2_ai_q110_ds0.vec $G/lrc_BlueSky_360p25_v2_ai_q110_ds2.vec \
         $G/lrc_RollerCoaster_1280x720p_5994_10bit_420_ai_q110_s2_f2.vec \
         /root/work/pnr/glvec_multi/*.vec; do
  echo "== $(basename $v) $(date +%T)" | tee -a $L
  bash $P/gl_sim_mac.sh $tag $v 2>&1 | tail -1 | tee -a $L
done
[ -x $R/gl/obj_t1/Vgdf_core ] || { echo "no model" | tee -a $L; exit 1; }
echo "== stress_stripe.vec, 12 parts $(date +%T)" | tee -a $L
BIN=$R/gl/obj_t1/Vgdf_core bash $P/gl_par.sh $tag /root/work/vec/stress_stripe.vec 12 > $R/gl/stress.log 2>&1 &
spid=$!
# placement colored by function, with the instance labels for the power split
cd $R
LABELS=$R/labels.txt python3 $P/layout_by_function.py $R $LEFS $R/layout_func.png $R/area_func.csv 2>&1 | tee -a $L
NOLEGEND=1 LABELS=$R/labels.txt python3 $P/layout_by_function.py $R $LEFS $R/layout_nolegend.png > /dev/null 2>&1
# switching activity of the two windows: 33 joint units of the 720p intra frame
# (24 with chroma) and of the 10-bit 4K intra frame, from segment 2 + 20
WINS="ksch:joint_ch_ks40_w xw:joint_ch_xw40_w"
for w in $WINS; do
  lab=${w%%:*}_b2b20k; vec=$G/${w#*:}.vec
  echo "== trace $lab $(date +%T)" | tee -a $L
  GDF_VCD=$R/gl/$lab.vcd GDF_VCD_SEG=2 GDF_VCD_SKIP=20 GDF_VCD_LEN=20000 \
    bash $P/gl_sim_mac.sh $tag $vec 2>&1 | tail -1 | tee -a $L
  python3 $P/vcd_to_pins.py $R/final.v $LIBS $R/gl/$lab.vcd $R/gl/${lab}_pins.vcd TOP.gdf_core 2>&1 | tee -a $L
  rm -f $R/gl/$lab.vcd
done
# the per-instance power report needs most of the memory: after the stress test
wait $spid
echo "== stress result $(date +%T)" | tee -a $L
tail -3 $R/gl/stress.log | tee -a $L
for w in $WINS; do
  lab=${w%%:*}_b2b20k
  echo "== power $lab $(date +%T)" | tee -a $L
  OUT=$R SDC=$P/gdf_mac.sdc PERIOD=2.5 VCD=$R/gl/${lab}_pins.vcd SCOPE=TOP/gdf_core RPT=power_vcd_$lab.rpt \
    INST_RPT=power_inst_$lab.rpt openroad -no_init -exit $P/power_vcd.tcl > $R/power_vcd_$lab.log 2>&1
  grep -E "annotated|Annotated|^Total|^Sequential|^Combinational|^Clock|^Macro|^Pad|POWER_VCD_DONE" $R/power_vcd_$lab.log | tee -a $L
  python3 $P/power_by_function.py $R/power_inst_$lab.rpt $R/labels.txt $R/power_func_$lab.csv 2>&1 | tee -a $L
  python3 $P/mem_power.py $R $R/power_inst_$lab.rpt $M 2>&1 | tee -a $L
done
echo GL_JOINT_CH_DONE | tee -a $L
