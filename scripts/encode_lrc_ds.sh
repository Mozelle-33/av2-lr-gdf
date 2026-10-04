#!/usr/bin/env bash
# Streams with a forced cross-component down-sampling filter (cfl_ds_filter_index
# 0 and 2; the regular streams pick 1), for the chroma LR verification.
# Output: /root/work/bit_lrc_ds/*.obu and their AVM_LRC_DUMP in /root/work/dumps_lrc.
set -uo pipefail
YUV=/mnt/g/AV2/data/yuv
OUT=/root/work/bit_lrc_ds
ENC=/root/build/avm-rel/avmenc
mkdir -p "$OUT"
one() {
  y4m=$1; ds=$2; q=$3; n=$4; bd=$5
  name=$(basename "$y4m" .y4m)_ai_q${q}_ds${ds}
  extra=()
  [ "$bd" = 10 ] && extra=(--bit-depth=10 --input-bit-depth=10)
  $ENC "$y4m" -o "$OUT/$name.obu" --passes=1 --end-usage=q --qp="$q" --use-fixed-qp-offsets=1 \
    --deltaq-mode=0 --enable-tpl-model=0 --enable-keyframe-filtering=0 --obu --limit="$n" \
    --cpu-used=2 --kf-min-dist=0 --kf-max-dist=0 --select-adaptive-ds="$ds" "${extra[@]}" \
    > "$OUT/$name.enc.log" 2>&1
  echo "$name $(stat -c %s "$OUT/$name.obu") bytes"
}
export -f one
export OUT ENC
{
  for ds in 0 2; do
    echo "$YUV/BlueSky_360p25_v2.y4m $ds 110 2 8"
    echo "$YUV/Stockholm_640x360_5994.y4m $ds 110 2 8"
    echo "$YUV/RollerCoaster_1280x720p_5994_10bit_420.y4m $ds 110 1 10"
  done
} | xargs -P 6 -L 1 bash -c 'one "$@"' _
OUT=/root/work/dumps_lrc bash /mnt/g/AV2/scripts/decode_lrc.sh "$OUT"
