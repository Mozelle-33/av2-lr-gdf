#!/usr/bin/env bash
# End-to-end check of the joint LR/GDF core (VS=1, PCW=1, LR=1): every GDF
# unit of the LR-enabled streams with the LR stripe of its frame; GDF error and
# correction, PC-Wiener classes and the final restored samples y = clip(LR +
# corr) are compared with the reference decoder.
# Usage: [MSTG=1|2] [FIP=0|1] [MAX=N] verify_joint.sh
set -uo pipefail
ROOT=/mnt/g/AV2
W=/root/work/jointvec
mkdir -p $W
python3 $ROOT/tools/make_pcw_rom.py >/dev/null
MAXARG=()
[ -n "${MAX:-}" ] && MAXARG=(--max "$MAX")
FIPARG=()
[ "${FIP:-0}" = 1 ] && FIPARG=(--fip)
bad=0
for g in /root/work/dumps_lr/*.gdfdump; do
  n=$(basename "$g" .gdfdump)
  l=/root/work/dumps_lr/$n.lrdump
  [ -f "$l" ] || continue
  OFF=(); [ -s "${g%.gdfdump}.gdfoff" ] && OFF=(--off "${g%.gdfdump}.gdfoff")   # units with GDF off
  gen=$(python3 $ROOT/tools/make_joint_vectors.py $W/$n.vec "$g" "$l" "${OFF[@]}" "${FIPARG[@]}" "${MAXARG[@]}" 2>&1 | tail -1)
  out=$(VS=1 PCW=1 LR=1 MSTG=${MSTG:-2} FIP=${FIP:-0} bash $ROOT/scripts/sim.sh $W/$n.vec 2>&1 | tail -3)
  echo "$n: $gen"
  echo "   $out"
  echo "$out" | grep -q "mismatches 0," || bad=1
done
[ $bad = 0 ] && echo VERIFY_JOINT_PASS || echo VERIFY_JOINT_FAIL
