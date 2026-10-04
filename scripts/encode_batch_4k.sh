#!/usr/bin/env bash
# 4K test set with loop restoration enabled (cpu-used=2, as encode_batch_lr.sh):
# the first 10 frames of the AOM CTC A1 sequence Crosswalk (3840x2160, 10 bit).
set -euo pipefail
YUV=/mnt/g/AV2/data/yuv
OUT=${OUT:-/root/work/bit_4k}
SPEED=${SPEED:-2}
mkdir -p "$OUT"
S=$YUV/Crosswalk_3840x2160_5994fps_10bit_420_f10.y4m
{
  for q in 110 160 210; do echo "$S ai $q 2 $SPEED $OUT"; done
  echo "$S ra 185 9 $SPEED $OUT"
} | xargs -P 4 -L 1 nice -n 5 bash /mnt/g/AV2/scripts/encode_one.sh | tee "$OUT/encode_summary.tsv"
