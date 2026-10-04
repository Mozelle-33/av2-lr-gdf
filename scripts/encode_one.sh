#!/usr/bin/env bash
# Encode one AOM CTC sequence with the AVM reference encoder.
# Usage: encode_one.sh <y4m> <ai|ra> <qp> <frames> <cpu-used> <outdir>
# Encoder options follow AV2 CTC v9 (CWG-G082) sections 4.1/4.2, except that
# --limit and --cpu-used are chosen by the caller.
set -euo pipefail
Y4M=$1; CFG=$2; QP=$3; N=$4; SPEED=$5; OUTDIR=$6
ENC=${AVMENC:-/root/build/avm-rel/avmenc}
name=$(basename "$Y4M" .y4m)
mkdir -p "$OUTDIR"
out="$OUTDIR/${name}_${CFG}_q${QP}_s${SPEED}_f${N}.obu"
log="${out%.obu}.enc.log"

common=(--passes=1 --end-usage=q --qp="$QP" --use-fixed-qp-offsets=1
        --deltaq-mode=0 --enable-tpl-model=0 --enable-keyframe-filtering=0
        --obu --limit="$N" --cpu-used="$SPEED" --psnr)
case "$name" in
  *360p*|*640x360*) ibc=(--enable-intrabc-ext=2) ;;  # classes A4/A5
  *) ibc=(--enable-intrabc-ext=1) ;;
esac
case "$CFG" in
  ai) cfg=(--kf-min-dist=0 --kf-max-dist=0) ;;
  ra) cfg=(--lag-in-frames=19 --auto-alt-ref=1 --min-gf-interval=16
           --max-gf-interval=16 --gf-min-pyr-height=4 --gf-max-pyr-height=4
           --kf-min-dist=65 --kf-max-dist=65) ;;
  *) echo "unknown config $CFG"; exit 1 ;;
esac
bd=()
case "$name" in *10bit*) bd=(--bit-depth=10 --input-bit-depth=10) ;; esac

start=$(date +%s.%N)
"$ENC" "$Y4M" -o "$out" "${common[@]}" "${cfg[@]}" "${ibc[@]}" "${bd[@]}" >"$log" 2>&1
end=$(date +%s.%N)
printf '%s\t%s\t%s\t%s\t%s\t%.1f s\t%s bytes\n' "$name" "$CFG" "$QP" "$SPEED" "$N" \
  "$(echo "$end - $start" | bc)" "$(stat -c %s "$out")"
