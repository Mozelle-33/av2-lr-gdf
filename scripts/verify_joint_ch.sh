#!/usr/bin/env bash
# End-to-end check of the joint luma LR/GDF + chroma LR stage (VS = 1, PCW = 1,
# LR = 1, CH = 1): every GDF unit of the LR-enabled streams with the LR stripe
# of its frame and, where the chroma LR is on, the chroma of its region
# (type-7 records): GDF error and correction, PC-Wiener classes, luma output y
# and the U, V outputs against the reference decoder.  ASIC pipeline (MSTG = 1)
# and FPGA pipeline with the fast inner product (MSTG = 2, FIP = 1).
# Usage: [MAX=N] [CFGS="1:0: 2:0: 2:1:--fip"] verify_joint_ch.sh   (MSTG:FIP:args)
set -uo pipefail
ROOT=/mnt/g/AV2
W=/root/work/jointvec_ch
mkdir -p $W
python3 $ROOT/tools/make_pcw_rom.py >/dev/null
MAXARG=()
[ -n "${MAX:-}" ] && MAXARG=(--max "$MAX")
bad=0
for g in /root/work/dumps_lr/*.gdfdump /root/work/dumps_4k/*.gdfdump; do
  [ -f "$g" ] || continue
  n=$(basename "$g" .gdfdump)
  l=$(dirname "$g")/$n.lrdump
  c=/root/work/dumps_lrc/$n.lrcdump
  [ -f "$l" ] && [ -f "$c" ] || continue
  OFF=(); [ -s "${g%.gdfdump}.gdfoff" ] && OFF=(--off "${g%.gdfdump}.gdfoff")   # units with GDF off
  for cf in ${CFGS:-1:0: 2:1:--fip}; do
    m=${cf%%:*}; rest=${cf#*:}; fp=${rest%%:*}; farg=${rest#*:}
    gen=$(python3 $ROOT/tools/make_joint_vectors.py $W/${n}_f$fp.vec "$g" "$l" --lrc "$c" "${OFF[@]}" $farg "${MAXARG[@]}" 2>&1 | tail -1)
    out=$(VS=1 PCW=1 LR=1 CH=1 MSTG=$m FIP=$fp MAXCH=32 AW=5 bash $ROOT/scripts/sim.sh $W/${n}_f$fp.vec 2>&1 | tail -1)
    echo "$n MSTG=$m FIP=$fp: $gen"
    echo "   $out"
    echo "$out" | grep -q "mismatches 0," || bad=1
  done
done
[ $bad = 0 ] && echo VERIFY_JOINT_CH_PASS || echo VERIFY_JOINT_CH_FAIL
