#!/usr/bin/env bash
# Joint LR/GDF core: segments over up to four adjacent restoration units of a
# stripe (tools/make_lr_vectors.py --stripes): every unit in its own
# coefficient bank, selected by the per-group side stream.
# Usage: [MSTG=1|2] [FIP=0|1] [MAX=N] verify_lr_stripes.sh [dump ...]
set -uo pipefail
ROOT=/mnt/g/AV2
W=/root/work/lrvec_st
mkdir -p $W
python3 $ROOT/tools/make_pcw_rom.py >/dev/null
DUMPS=("$@")
[ ${#DUMPS[@]} -eq 0 ] && DUMPS=(/root/work/dumps_lr/*.lrdump)
MAXARG=()
[ -n "${MAX:-}" ] && MAXARG=(--max "$MAX")
bad=0
for d in "${DUMPS[@]}"; do
  n=$(basename "$d" .lrdump)
  gen=$(python3 $ROOT/tools/make_lr_vectors.py $W/$n.vec "$d" --stripes "${MAXARG[@]}" 2>&1 | tail -1)
  out=$(VS=1 PCW=1 LR=1 MAXCH=256 AW=8 MSTG=${MSTG:-2} FIP=${FIP:-0} bash $ROOT/scripts/sim.sh $W/$n.vec 2>&1 | tail -3)
  echo "$n: $gen"
  echo "   $out"
  echo "$out" | grep -q "mismatches 0," || bad=1
done
[ $bad = 0 ] && echo VERIFY_LR_STRIPES_PASS || echo VERIFY_LR_STRIPES_FAIL
