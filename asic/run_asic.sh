#!/usr/bin/env bash
# Usage: run_asic.sh <full 0|1> <delay_ps> [mstg=1] [booth=0|1] [maxch=1024] [aw=10]
set -euo pipefail
full=${1:-0}; delay=${2:-2500}; mstg=${3:-1}; booth=${4:-0}; maxch=${5:-1024}; aw=${6:-10}
bo=""; [ "$booth" = 1 ] && bo="-booth"
out=/root/work/asic/full${full}_m${mstg}_b${booth}_d${delay}
mkdir -p "$out"
sed -e "s/@MAXCH@/$maxch/" -e "s/@AW@/$aw/" -e "s/@FULL@/$full/" -e "s/@MSTG@/$mstg/" \
    -e "s/@BOOTH@/$bo/" -e "s/@DELAY@/$delay/g" -e "s#@OUT@#$out#g" \
    /mnt/g/AV2/asic/synth_yosys.ys > "$out/synth.ys"
/opt/yosys/bin/yosys -q -l "$out/yosys.log" -s "$out/synth.ys"
grep -E "Chip area" "$out/stat.txt" | tail -1
grep -E "WireLoad|Delay =" "$out/yosys.log" | tail -2
