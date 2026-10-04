#!/usr/bin/env bash
# Post-layout checks of the routed joint stage with its SRAM macros (the set
# of gl_joint_ch_mac.sh, extended): gate-level simulation (gl_sim_mac.sh) of
#   * the vectors of gl_joint_ch_mac.sh: joint units with and without chroma,
#     Wiener-NS units, segments across restoration units, chroma stripes (three
#     down-sampling filters, 10 bit) and chroma segments (glvec_multi), the
#     3,000 GDF stress units in 12 parallel parts,
#   * glvec_r4: full-width 720p stripes with chroma, with and without blocks
#     with GDF off (side stream in_gdf), a full-width 4K stripe with chroma and
#     bank reloads, 300 units and 60 segments of the luma LR stress set and 150
#     segments of the chroma stress set;
# then the switching activity of two windows inside full-width stripes (10,000
# cycles of a 720p intra stripe from cycle 600, 20,000 cycles of a 10-bit 4K
# intra stripe from cycle 6,000: 7.5 luma samples per cycle, as in operation)
# and the OpenSTA power with the extracted parasitics and the macro models
# (720p: per instance, split by function; 4K: totals, macros, chroma unit).
# Usage: [GLJ=8] [MACRO_DIR=dir] gl_joint_ch_r4.sh <tag>   (log: <run>/gl_joint_ch_r4.log)
set -uo pipefail
tag=$1
ROOT=/mnt/g/AV2
P=$ROOT/asic/pnr
R=/root/work/pnr/$tag
G=/root/work/pnr/glvec
G4=/root/work/pnr/glvec_r4
M=${MACRO_DIR:-/root/work/macros}
export MACRO_DIR=$M
PLAT=/root/work/pnr/orfs/flow/platforms/nangate45
LIBS=$PLAT/lib/NangateOpenCellLibrary_typical.lib,$(ls $M/*/*.lib | tr '\n' ',' | sed 's/,$//')
LEFS=$PLAT/lef/NangateOpenCellLibrary.macro.mod.lef,$(ls $M/*/*.lef | tr '\n' ',' | sed 's/,$//')
L=$R/gl_joint_ch_r4.log
: > $L
export TRACE=1 GLJ=${GLJ:-8}
for v in $G/joint_ks40.vec $G/lr_st40.vec $G/stripes10.vec $G/joint_ch_ks40.vec \
         $G/lrc_BlueSky_360p25_v2_ai_q110_ds0.vec $G/lrc_BlueSky_360p25_v2_ai_q110_ds2.vec \
         $G/lrc_RollerCoaster_1280x720p_5994_10bit_420_ai_q110_s2_f2.vec \
         $G4/wide_ks2.vec $G4/wide_ks_off.vec $G4/wide_xw1.vec \
         $G4/lr_stress300.vec $G4/lr_stress_st60.vec $G4/lrc_stress150.vec \
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
# switching activity of the two windows inside full-width stripes
trace() {  # label vec skip len
  echo "== trace $1 $(date +%T)" | tee -a $L
  GDF_VCD=$R/gl/$1.vcd GDF_VCD_SEG=0 GDF_VCD_SKIP=$3 GDF_VCD_LEN=$4 \
    bash $P/gl_sim_mac.sh $tag $2 2>&1 | tail -1 | tee -a $L
  python3 $P/vcd_to_pins.py $R/final.v $LIBS $R/gl/$1.vcd $R/gl/$1_pins.vcd TOP.gdf_core 2>&1 | tee -a $L
  rm -f $R/gl/$1.vcd
}
trace ksw10k $G4/wide_ks2.vec 600 10000
trace xww20k $G4/wide_xw1.vec 6000 20000
# the per-instance power report needs most of the memory: after the stress test
wait $spid
echo "== stress result $(date +%T)" | tee -a $L
tail -3 $R/gl/stress.log | tee -a $L
(
  lab=ksw10k
  OUT=$R SDC=$P/gdf_mac.sdc PERIOD=2.5 VCD=$R/gl/${lab}_pins.vcd SCOPE=TOP/gdf_core RPT=power_vcd_$lab.rpt \
    INST_RPT=power_inst_$lab.rpt openroad -no_init -exit $P/power_vcd.tcl > $R/power_vcd_$lab.log 2>&1
  {
    grep -E "annotated|Annotated|^Total|^Sequential|^Combinational|^Clock|^Macro|^Pad|POWER_VCD_DONE" $R/power_vcd_$lab.log
    python3 $P/power_by_function.py $R/power_inst_$lab.rpt $R/labels.txt $R/power_func_$lab.csv
    python3 $P/mem_power.py $R $R/power_inst_$lab.rpt $M
  } 2>&1 | sed "s/^/$lab: /" >> $L
  echo "$lab DONE $(date +%T)" >> $L
) &
(
  lab=xww20k
  OUT=$R SDC=$P/gdf_mac.sdc PERIOD=2.5 VCD=$R/gl/${lab}_pins.vcd SCOPE=TOP/gdf_core RPT=power_vcd_$lab.rpt \
    LABELS=$R/labels.txt LABEL=lrc openroad -no_init -exit $P/power_vcd_lite.tcl > $R/power_vcd_$lab.log 2>&1
  {
    grep -E "annotated|Annotated|^Total|^Sequential|^Combinational|^Clock|^Macro|^Pad|instances|macros:|POWER_VCD_DONE" $R/power_vcd_$lab.log
    python3 $P/mem_power.py $R $R/power_vcd_${lab}_macros.rpt $M
    awk 'NF == 5 && $1 ~ /^[0-9.e+-]+$/ { s += $4; n++ } END { printf "chroma unit: %d instances, %.2f mW\n", n, s * 1e3 }' $R/power_vcd_${lab}_lrc.rpt
  } 2>&1 | sed "s/^/$lab: /" >> $L
  echo "$lab DONE $(date +%T)" >> $L
) &
wait
echo GL_JOINT_CH_R4_DONE | tee -a $L
