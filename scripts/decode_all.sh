#!/usr/bin/env bash
# Profile every *completed* encoded stream (listed in encode_summary.tsv) and
# dump GDF units (first AVM_GDF_DUMP_MAXFRAMES GDF frames of each stream).
# Usage: decode_all.sh [dump:0|1]
set -euo pipefail
DUMP=${1:-1}
BIT=${BIT:-/root/work/bit}
OUT=${OUT:-/mnt/g/AV2/data/profile}
JOBS=${JOBS:-8}
export AVM_GDF_DUMP_MAXFRAMES=${AVM_GDF_DUMP_MAXFRAMES:-6}
mkdir -p "$OUT"
awk -F'\t' -v d="$BIT" '{printf "%s/%s_%s_q%s_s%s_f%s.obu\n", d, $1, $2, $3, $4, $5}' \
  "$BIT/encode_summary.tsv" |
  xargs -P "$JOBS" -I{} bash /mnt/g/AV2/scripts/decode_profile.sh {} "$OUT" "$DUMP"
python3 /mnt/g/AV2/analysis/profile_report.py "$OUT" >/dev/null
echo "report: $OUT/profile_report.md"
