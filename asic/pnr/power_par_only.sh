#!/usr/bin/env bash
# The OpenSTA steps of gl_power_par.sh on existing pin-level VCDs, in parallel:
# the 720p window with the per-instance report and the split by function, the
# 4K window with the totals, the macros and the chroma unit.
# Usage: [MACRO_DIR=dir] power_par_only.sh <tag>
set -uo pipefail
tag=$1
P=/mnt/g/AV2/asic/pnr
R=/root/work/pnr/$tag
M=${MACRO_DIR:-/root/work/macros}
export MACRO_DIR=$M
L=$R/power_par.log
: > $L
(
  lab=ksch_b2b20k
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
echo POWER_PAR_DONE >> $L
