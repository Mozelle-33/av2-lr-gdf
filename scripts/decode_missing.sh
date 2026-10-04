#!/usr/bin/env bash
# Profile/dump only the streams that have no result in the profile dir yet.
set -euo pipefail
BIT=${BIT:-/root/work/bit}
OUT=${OUT:-/mnt/g/AV2/data/profile}
JOBS=${JOBS:-8}
export AVM_GDF_DUMP_MAXFRAMES=${AVM_GDF_DUMP_MAXFRAMES:-6}
awk -F'\t' -v d="$BIT" '{printf "%s_%s_q%s_s%s_f%s\n", $1, $2, $3, $4, $5}' "$BIT/encode_summary.tsv" |
  while read -r n; do [ -f "$OUT/$n.summary.tsv" ] || echo "$BIT/$n.obu"; done |
  xargs -r -P "$JOBS" -I{} bash /mnt/g/AV2/scripts/decode_profile.sh {} "$OUT" 1
python3 /mnt/g/AV2/analysis/profile_report.py "$OUT" >/dev/null
