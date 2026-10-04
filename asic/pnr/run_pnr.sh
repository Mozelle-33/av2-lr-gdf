#!/usr/bin/env bash
# Synthesis + OpenROAD place and route of one gdf_core configuration.
# Usage: [PCW=0|1] [LR=0|1] [CH=0|1] run_pnr.sh <tag> <VS> <FIP> [util=55] [period=2.5] [threads=12]
set -euo pipefail
tag=$1; vs=$2; fip=$3; util=${4:-55}; period=${5:-2.5}; thr=${6:-12}
P=/mnt/g/AV2/asic/pnr
plat=/root/work/pnr/orfs/flow/platforms/nangate45
out=/root/work/pnr/$tag; mkdir -p $out
lib=/root/work/pnr/nangate45_dontuse.lib
[ -f $lib ] || python3 $P/mark_dont_use.py $plat/lib/NangateOpenCellLibrary_typical.lib $lib \
  TAPCELL_X1 FILLCELL_X1 AOI211_X1 OAI211_X1
sed -e "s/@VS@/$vs/" -e "s/@FIP@/$fip/" -e "s/@PCW@/${PCW:-0}/" -e "s/@LR@/${LR:-0}/" -e "s/@CH@/${CH:-0}/" \
    -e "s#@LIB@#$lib#g" -e "s/@DELAY@/2500/g" \
    -e "s#@OUT@#$out#g" $P/synth_pnr.ys > $out/synth.ys
echo "synthesis $(date +%T)"
nice -n 5 /opt/yosys/bin/yosys -q -l $out/yosys.log -s $out/synth.ys
grep -E "Chip area" $out/stat.txt | tail -1
# an undriven wire (e.g. a memory port that was not exposed) would become a
# constant: stop before place and route
if grep -q "is used but has no driver" $out/yosys.log; then
  grep "is used but has no driver" $out/yosys.log | head -5; echo "ERROR: undriven wires"; exit 1
fi
echo "pnr $(date +%T)"
cd $out
NETLIST=$out/netlist.v OUT=$out SDC=$P/gdf.sdc PERIOD=$period UTIL=$util THREADS=$thr \
  nice -n 5 openroad -no_init -exit $P/pnr.tcl > $out/pnr.log 2>&1 || { tail -30 $out/pnr.log; exit 1; }
grep -E "^STAGE|_WNS|CORE_AREA|Design area|PNR_DONE" $out/pnr.log
