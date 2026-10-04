#!/usr/bin/env bash
# Dump the chroma restoration unit stripes with LR off (AVM_LRCOFF_DUMP: LRSC
# records with rtype 0 and the frame index, see tcas_instr.h) of every
# LR-enabled stream, beside its .lrcdump; the MD5 of the instrumented decoder
# must match the release decoder.
# Usage: decode_lrcoff.sh [bitstream dir...]   (default /root/work/bit_lr /root/work/bit_4k)
set -uo pipefail
REL=/root/build/avm-rel/avmdec
INS=/root/build/avm-instr/avmdec
OUT=${OUT:-/root/work/dumps_lrc}
JOBS=${JOBS:-12}
dirs=("$@")
[ ${#dirs[@]} -eq 0 ] && dirs=(/root/work/bit_lr /root/work/bit_4k)
one() {
  bs=$1; n=$(basename "$bs" .obu)
  m1=$($REL "$bs" --md5 --threads=1 2>/dev/null | cut -d' ' -f1)
  m2=$(AVM_LRCOFF_DUMP=$OUT/$n.lrcoff $INS "$bs" --md5 --threads=1 2>/dev/null | cut -d' ' -f1)
  printf '%s\t%s\t%s\n' "$n" "$([ "$m1" = "$m2" ] && echo md5_ok || echo MD5_MISMATCH)" \
    "$(stat -c %s "$OUT/$n.lrcoff" 2>/dev/null)"
}
export -f one
export REL INS OUT
for d in "${dirs[@]}"; do ls "$d"/*.obu; done | xargs -P "$JOBS" -I{} bash -c 'one {}' | sort
echo DECODE_LRCOFF_DONE
