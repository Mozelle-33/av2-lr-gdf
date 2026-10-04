#!/usr/bin/env bash
# Joint LR/GDF core (VS=1, PCW=1, LR=1): LR vectors from the LR stripe dumps
# (AVM_LR_DUMP), restored samples and LR classes checked bit-exactly.
# Usage: [MSTG=1|2] [FIP=0|1] [MAX=N] verify_lr.sh [dump ...]
set -uo pipefail
ROOT=/mnt/g/AV2
W=/root/work/lrvec
mkdir -p $W
python3 $ROOT/tools/make_pcw_rom.py >/dev/null
DUMPS=("$@")
[ ${#DUMPS[@]} -eq 0 ] && DUMPS=(/root/work/dumps_lr/*.lrdump)
MAXARG=()
[ -n "${MAX:-}" ] && MAXARG=(--max "$MAX")
tot=0; bad=0
for d in "${DUMPS[@]}"; do
  n=$(basename "$d" .lrdump)
  python3 $ROOT/tools/make_lr_vectors.py $W/$n.vec "$d" "${MAXARG[@]}" >/dev/null || { echo "vecgen failed $n"; bad=1; continue; }
  out=$(VS=1 PCW=1 LR=1 MSTG=${MSTG:-2} FIP=${FIP:-0} bash $ROOT/scripts/sim.sh $W/$n.vec 2>&1 | tail -3)
  echo "$n: $out"
  echo "$out" | grep -q "mismatches 0," || bad=1
done
[ $bad = 0 ] && echo VERIFY_LR_PASS || echo VERIFY_LR_FAIL
