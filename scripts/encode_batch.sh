#!/usr/bin/env bash
# Batch-encode the GDF test set with AVM (parallel, one job per core).
#   AI: QP 110/160/210, 8 frames;  RA: QP 135/185/235, 17 frames (one full
#   16-frame GOP, so every GDF inter table set refDstIdx 1..5 is exercised).
set -euo pipefail
YUV=/mnt/g/AV2/data/yuv
OUT=${OUT:-/root/work/bit}
SPEED=${SPEED:-5}
JOBS=${JOBS:-30}
SEQS=(BlueSky_360p25_v2 RedKayak_360_2997 Stockholm_640x360_5994
      KristenAndSara_1280x720_60 RollerCoaster_1280x720p_5994_10bit_420)
mkdir -p "$OUT"
{
  for s in "${SEQS[@]}"; do
    for q in 110 160 210; do echo "$YUV/$s.y4m ai $q 8 $SPEED $OUT"; done
    for q in 135 185 235; do echo "$YUV/$s.y4m ra $q 17 $SPEED $OUT"; done
  done
} | xargs -P "$JOBS" -L 1 bash /mnt/g/AV2/scripts/encode_one.sh | tee "$OUT/encode_summary.tsv"
