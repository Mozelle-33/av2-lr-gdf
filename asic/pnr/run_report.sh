#!/usr/bin/env bash
# Usage: run_report.sh <tag> [period=2.5]
tag=$1; period=${2:-2.5}
out=/root/work/pnr/$tag
cd $out
OUT=$out SDC=/mnt/g/AV2/asic/pnr/gdf.sdc PERIOD=$period \
  openroad -no_init -exit /mnt/g/AV2/asic/pnr/report.tcl > $out/report.log 2>&1
grep -E "FINAL_WNS|FMAX|CELL_AREA|CORE_AREA|CELL_KGE|REPORT_DONE|Error|ERROR" $out/report.log
grep -E "^Total|^Sequential|^Combinational|^Clock|^Macro|^Pad" $out/power_vectorless.rpt
