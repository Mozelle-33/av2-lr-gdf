#!/usr/bin/env bash
# Post-layout power of the routed joint stage over a further activity window:
# gate-level simulation of <vec> with a VCD from cycle <skip> of segment <seg>
# for <len> cycles, pin-level VCD, OpenSTA power with the extracted parasitics
# and the split by function (labels of layout_by_function.py), as in
# gl_joint_ch.sh.  Usage: gl_power_window.sh <tag> <vec> <label> [seg] [skip] [len]
set -euo pipefail
tag=$1; vec=$2; lab=$3; seg=${4:-2}; skip=${5:-20}; len=${6:-20000}
P=/mnt/g/AV2/asic/pnr
R=/root/work/pnr/$tag
L=$R/power_$lab.log
: > $L
echo "== trace $lab $(date +%T)" | tee -a $L
GDF_VCD=$R/gl/$lab.vcd GDF_VCD_SEG=$seg GDF_VCD_SKIP=$skip GDF_VCD_LEN=$len TRACE=1 \
  bash $P/gl_sim.sh $tag $vec 2>&1 | tail -1 | tee -a $L
python3 $P/vcd_to_pins.py $R/final.v /root/work/pnr/orfs/flow/platforms/nangate45/lib/NangateOpenCellLibrary_typical.lib \
  $R/gl/$lab.vcd $R/gl/${lab}_pins.vcd TOP.gdf_core.u_pnr 2>&1 | tee -a $L
rm -f $R/gl/$lab.vcd
cd $R
OUT=$R SDC=$P/gdf.sdc PERIOD=2.5 VCD=$R/gl/${lab}_pins.vcd SCOPE=TOP/gdf_core/u_pnr RPT=power_vcd_$lab.rpt \
  INST_RPT=power_inst_$lab.rpt openroad -no_init -exit $P/power_vcd.tcl > $R/power_vcd_$lab.log 2>&1
grep -E "annotated|Annotated|^Total|^Sequential|^Combinational|^Clock|POWER_VCD_DONE" $R/power_vcd_$lab.log | tee -a $L
python3 $P/power_by_function.py $R/power_inst_$lab.rpt $R/labels.txt $R/power_func_$lab.csv 2>&1 | tee -a $L
echo "POWER_WINDOW_DONE $lab $(date +%T)" | tee -a $L
