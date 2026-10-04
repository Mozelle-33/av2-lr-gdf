#!/usr/bin/env bash
# Profile the AVM decoder on one bitstream and optionally dump GDF units.
# Usage: decode_profile.sh <bitstream.obu> <outdir> [dump:0|1]
#   - release decoder: 3 timed runs (--summary), MD5 of the decoded video
#   - instrumented decoder (TCAS_INSTR): per-stage timing, MD5 must match
#   - optional: per-unit GDF dump for golden-model verification
set -euo pipefail
BS=$1; OUT=$2; DUMP=${3:-0}
REL=${AVMDEC_REL:-/root/build/avm-rel/avmdec}
INS=${AVMDEC_INS:-/root/build/avm-instr/avmdec}
name=$(basename "$BS" .obu)
mkdir -p "$OUT"

md5_rel=$("$REL" "$BS" --md5 --threads=1 2>/dev/null | awk '{print $1}')
# Timing: user+sys CPU time of the single-threaded decoder (immune to the WSL
# wall-clock adjustments that make avmdec --summary report negative times).
best=""
tf=$(mktemp)
for r in 1 2 3; do
  /usr/bin/time -f '%U %S' -o "$tf" "$REL" "$BS" --noblit --threads=1 >/dev/null 2>&1
  t=$(tail -1 "$tf" | awk '{printf "%d", ($1 + $2) * 1e6}')
  if [ -z "$best" ] || [ "$t" -lt "$best" ]; then best=$t; fi
done
rm -f "$tf"

md5_ins=$(AVM_STAGE_TIMING=1 "$INS" "$BS" --md5 --threads=1 2>"$OUT/$name.stages.txt" | awk '{print $1}')

if [ "$DUMP" = "1" ]; then
  DUMPDIR=${DUMPDIR:-/root/work/dumps}
  mkdir -p "$DUMPDIR"
  AVM_GDF_DUMP="$DUMPDIR/$name.gdfdump" "$INS" "$BS" --noblit --threads=1 >/dev/null 2>&1
fi

match=$([ "$md5_rel" = "$md5_ins" ] && echo md5_ok || echo MD5_MISMATCH)
printf '%s\t%s\t%s\t%s\n' "$name" "$best" "$match" "$md5_rel" | tee "$OUT/$name.summary.tsv"
