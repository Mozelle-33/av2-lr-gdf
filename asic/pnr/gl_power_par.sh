#!/usr/bin/env bash
# The two power windows of gl_joint_ch_mac.sh in parallel: the 720p window
# (its trace may already run; then wait for it) with the full per-instance
# report and the split by function, and the 4K window with the totals, the
# macros and the chroma unit (power_vcd_lite.tcl, little memory).
# Usage: [MACRO_DIR=dir] gl_power_par.sh <tag> [ksch_running=1]
set -uo pipefail
tag=$1; running=${2:-1}
P=/mnt/g/AV2/asic/pnr
R=/root/work/pnr/$tag
G=/root/work/pnr/glvec
M=${MACRO_DIR:-/root/work/macros}
export MACRO_DIR=$M
PLAT=/root/work/pnr/orfs/flow/platforms/nangate45
LIBS=$PLAT/lib/NangateOpenCellLibrary_typical.lib,$(ls $M/*/*.lib | tr '\n' ',' | sed 's/,$//')
L=$R/gl_power_par.log
trace() {   # label vec
  GDF_VCD=$R/gl/$1.vcd GDF_VCD_SEG=2 GDF_VCD_SKIP=20 GDF_VCD_LEN=20000 TRACE=1 \
    bash $P/gl_sim_mac.sh $tag $2 2>&1 | tail -1 | sed "s/^/$1 trace: /" >> $L
}
pins() {    # label
  python3 $P/vcd_to_pins.py $R/final.v $LIBS $R/gl/$1.vcd $R/gl/$1_pins.vcd TOP.gdf_core 2>&1 | sed "s/^/$1: /" >> $L
  rm -f $R/gl/$1.vcd
}
(
  lab=ksch_b2b20k
  if [ "$running" = 1 ]; then
    while pgrep -f "Vgdf_core $G/joint_ch_ks40_w.vec" > /dev/null; do sleep 10; done
  else
    trace $lab $G/joint_ch_ks40_w.vec
  fi
  echo "$lab pins $(date +%T)" >> $L; pins $lab
  echo "$lab power $(date +%T)" >> $L
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
  lab=xw_b2b20k
  echo "$lab trace $(date +%T)" >> $L; trace $lab $G/joint_ch_xw40_w.vec
  echo "$lab pins $(date +%T)" >> $L; pins $lab
  echo "$lab power $(date +%T)" >> $L
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
echo GL_POWER_PAR_DONE >> $L
