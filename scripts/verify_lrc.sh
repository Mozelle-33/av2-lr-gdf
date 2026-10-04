#!/usr/bin/env bash
# Chroma LR of the joint stage (CH = 1): every chroma LR stripe of every dumped
# stream (/root/work/dumps_lrc, scripts/decode_lrc.sh) on the RTL, for the ASIC
# pipeline (MSTG = 1) and the FPGA pipeline with the fast inner product
# (MSTG = 2, FIP = 1).  Usage: [CFGS="1:0 2:1"] [DUMPS=dir] verify_lrc.sh
set -uo pipefail
ROOT=/mnt/g/AV2
V=/root/work/lrcvec
mkdir -p $V
CFGS=${CFGS:-"1:0 2:1"}
bad=0
tot=0
for d in ${DUMPS:-/root/work/dumps_lrc}/*.lrcdump; do
  n=$(basename "$d" .lrcdump)
  gen=$(python3 $ROOT/tools/make_lrc_vectors.py $V/$n.vec "$d" | tail -1)
  case "$gen" in *": 0 chroma segments"*) continue ;; esac
  echo "$n: $gen"
  for cf in $CFGS; do
    m=${cf%:*}; fp=${cf#*:}
    out=$(VS=1 PCW=1 LR=1 CH=1 MSTG=$m FIP=$fp MAXCH=256 AW=8 bash $ROOT/scripts/sim.sh $V/$n.vec 2>&1 | tail -1)
    echo "   MSTG=$m FIP=$fp: $out"
    echo "$out" | grep -q "mismatches 0," || bad=1
    s=$(echo "$out" | sed -n 's/.*restored samples checked \([0-9]*\).*/\1/p')
    tot=$((tot + ${s:-0}))
  done
done
echo "chroma samples checked (all configurations): $tot"
[ $bad = 0 ] && echo VERIFY_LRC_PASS || echo VERIFY_LRC_FAIL
