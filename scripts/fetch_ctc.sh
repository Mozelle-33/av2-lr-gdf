#!/usr/bin/env bash
# Download the selected AOM CTC test sequences (Xiph.Org mirror) and verify MD5.
set -euo pipefail
# Works from Git Bash (/g/...) and from WSL (/mnt/g/...).
if [ -d /mnt/g ]; then DST=/mnt/g/AV2/data/yuv; else DST=/g/AV2/data/yuv; fi
BASE=https://media.xiph.org/video/aomctc/test_set
mkdir -p "$DST"
cd "$DST"
FILES=(
  a4_360p/BlueSky_360p25_v2.y4m
  a4_360p/RedKayak_360_2997.y4m
  a4_360p/Stockholm_640x360_5994.y4m
  a3_720p/KristenAndSara_1280x720_60.y4m
  a3_720p/RollerCoaster_1280x720p_5994_10bit_420.y4m
)
for f in a4_360p/a4_360p.md5 a4_360p/BlueSky_360p25_v2.md5 a3_720p/a3_720p.md5; do
  curl -sS -f -o "$(basename "$f")" "$BASE/$f"
done
for f in "${FILES[@]}"; do
  name=$(basename "$f")
  if [ ! -s "$name" ]; then
    echo "downloading $name"
    curl -sS -f -o "$name.part" "$BASE/$f" && mv "$name.part" "$name"
  fi
done
echo "--- md5 check"
# a3/a4 lists use "md5  name"; BlueSky_360p25_v2.md5 is "MD5 hash of name:\n<md5>".
cat a4_360p.md5 a3_720p.md5 | tr -d '\r' > all.md5
printf '%s  BlueSky_360p25_v2.y4m\n' "$(tr -d '\r' < BlueSky_360p25_v2.md5 | tail -1)" >> all.md5
for f in "${FILES[@]}"; do
  name=$(basename "$f")
  want=$(awk -v n="$name" '$2 == n {print $1}' all.md5 | head -1 || true)
  got=$(md5sum "$name" | awk '{print $1}')
  if [ -z "$want" ]; then echo "$name: no reference md5 ($got)";
  elif [ "$want" = "$got" ]; then echo "$name: OK";
  else echo "$name: MISMATCH want=$want got=$got"; fi
done
ls -la "$DST"
