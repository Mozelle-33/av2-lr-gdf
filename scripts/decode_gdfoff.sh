#!/usr/bin/env bash
# Dump the GDF units with GDF off (block flag or local mode; AVM_GDFOFF_DUMP,
# same record layout as the .gdfdump of the units with GDF on) of every
# LR-enabled stream, for the same frames as the existing .gdfdump files; the
# MD5 of the instrumented decoder must match the release decoder.
# Usage: decode_gdfoff.sh        (bit_lr -> dumps_lr, 6 frames; bit_4k -> dumps_4k, 10 frames)
set -uo pipefail
REL=/root/build/avm-rel/avmdec
INS=/root/build/avm-instr/avmdec
JOBS=${JOBS:-12}
one() {
  bs=$1; out=$2; mf=$3; n=$(basename "$bs" .obu)
  m1=$($REL "$bs" --md5 --threads=1 2>/dev/null | cut -d' ' -f1)
  m2=$(AVM_GDFOFF_DUMP=$out/$n.gdfoff AVM_GDF_DUMP_MAXFRAMES=$mf $INS "$bs" --md5 --threads=1 2>/dev/null | cut -d' ' -f1)
  printf '%s\t%s\t%s\n' "$n" "$([ "$m1" = "$m2" ] && echo md5_ok || echo MD5_MISMATCH)" \
    "$(stat -c %s "$out/$n.gdfoff" 2>/dev/null)"
}
export -f one
export REL INS
{
  for bs in /root/work/bit_lr/*.obu; do echo "$bs /root/work/dumps_lr 6"; done
  for bs in /root/work/bit_4k/*.obu; do echo "$bs /root/work/dumps_4k 10"; done
} | xargs -P "$JOBS" -L 1 bash -c 'one "$0" "$1" "$2"' | sort
echo DECODE_GDFOFF_DONE
