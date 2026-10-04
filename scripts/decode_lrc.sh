#!/usr/bin/env bash
# Dump the chroma LR records (AVM_LRC_DUMP: LRSC chroma stripes, LRSL
# down-sampled luma) of every LR-enabled stream; the MD5 of the instrumented
# decoder must match the release decoder.
# Usage: decode_lrc.sh [bitstream dir...]   (default /root/work/bit_lr /root/work/bit_4k)
set -uo pipefail
REL=/root/build/avm-rel/avmdec
INS=/root/build/avm-instr/avmdec
OUT=${OUT:-/root/work/dumps_lrc}
JOBS=${JOBS:-8}
mkdir -p "$OUT"
dirs=("$@")
[ ${#dirs[@]} -eq 0 ] && dirs=(/root/work/bit_lr /root/work/bit_4k)
one() {
  bs=$1; n=$(basename "$bs" .obu)
  m1=$($REL "$bs" --md5 --threads=1 2>/dev/null | cut -d' ' -f1)
  m2=$(AVM_LRC_DUMP=$OUT/$n.lrcdump $INS "$bs" --md5 --threads=1 2>/dev/null | cut -d' ' -f1)
  c=$(python3 /mnt/g/AV2/analysis/lrc_dump.py --count "$OUT/$n.lrcdump")
  printf '%s\t%s\t%s\n' "$n" "$([ "$m1" = "$m2" ] && echo md5_ok || echo MD5_MISMATCH)" "$c"
}
export -f one
export REL INS OUT
for d in "${dirs[@]}"; do ls "$d"/*.obu; done | xargs -P "$JOBS" -I{} bash -c 'one {}' | sort
