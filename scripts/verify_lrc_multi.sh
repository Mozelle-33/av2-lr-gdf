#!/usr/bin/env bash
# Chroma bank switching of the joint stage (CH = 1): segments over two or more
# adjacent chroma restoration units of every dumped stream (make_lrc_vectors.py
# --multi), whose up to four filters per plane sit in banks 0..3 selected per
# strip by the side stream, on the RTL for the ASIC pipeline (MSTG = 1), the
# FPGA pipeline (MSTG = 2) and the FPGA pipeline with the fast inner product.
# Usage: [CFGS="1:0 2:0 2:1"] verify_lrc_multi.sh
set -uo pipefail
ROOT=/mnt/g/AV2
V=/root/work/lrcvec_multi
mkdir -p $V
CFGS=${CFGS:-"1:0 2:0 2:1"}
bad=0
tot=0
for d in /root/work/dumps_lrc/*.lrcdump /root/work/dumps_lrc_ds/*.lrcdump; do
  n=$(basename "$d" .lrcdump)
  gen=$(python3 $ROOT/tools/make_lrc_vectors.py $V/$n.vec "$d" --multi 2040 | tail -1)
  case "$gen" in *": 0 chroma segments"*) continue ;; esac
  echo "$n: $gen"
  for cf in $CFGS; do
    m=${cf%:*}; fp=${cf#*:}
    out=$(VS=1 PCW=1 LR=1 CH=1 MSTG=$m FIP=$fp MAXCH=1024 AW=10 bash $ROOT/scripts/sim.sh $V/$n.vec 2>&1 | tail -1)
    echo "   MSTG=$m FIP=$fp: $out"
    echo "$out" | grep -q "mismatches 0," || bad=1
    s=$(echo "$out" | sed -n 's/.*restored samples checked \([0-9]*\).*/\1/p')
    tot=$((tot + ${s:-0}))
  done
done
echo "chroma samples checked (all configurations): $tot"
[ $bad = 0 ] && echo VERIFY_LRC_MULTI_PASS || echo VERIFY_LRC_MULTI_FAIL
