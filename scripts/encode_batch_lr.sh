#!/usr/bin/env bash
# Second test set with loop restoration enabled (cpu-used=2; AVM disables LR
# at cpu-used >= 5). Used for CTC-like decoder profiling and LR+GDF checks.
set -euo pipefail
YUV=/mnt/g/AV2/data/yuv
OUT=${OUT:-/root/work/bit_lr}
SPEED=${SPEED:-2}
JOBS=${JOBS:-24}
mkdir -p "$OUT"
{
  for s in BlueSky_360p25_v2 RedKayak_360_2997 Stockholm_640x360_5994; do
    for q in 110 160 210; do echo "$YUV/$s.y4m ai $q 4 $SPEED $OUT"; done
    for q in 135 185 235; do echo "$YUV/$s.y4m ra $q 17 $SPEED $OUT"; done
  done
  for s in KristenAndSara_1280x720_60 RollerCoaster_1280x720p_5994_10bit_420; do
    for q in 110 160 210; do echo "$YUV/$s.y4m ai $q 2 $SPEED $OUT"; done
  done
} | xargs -P "$JOBS" -L 1 nice -n 5 bash /mnt/g/AV2/scripts/encode_one.sh | tee "$OUT/encode_summary.tsv"
