#!/usr/bin/env bash
# Print area summary of all ASIC runs (Nangate45: NAND2_X1 = 0.798 um^2).
cd /root/work/asic
for d in full*_d*; do
  [ -f "$d/stat.txt" ] || continue
  a=$(grep "Chip area for module" "$d/stat.txt" | tail -1 | awk '{print $NF}')
  s=$(grep "used for sequential" "$d/stat.txt" | tail -1 | awk '{print $(NF-1)}')
  ff=$(grep -E "^ +DFF_X1 " "$d/stat.txt" | tail -1 | awk '{print $2}')
  awk -v d="$d" -v a="$a" -v s="$s" -v ff="$ff" 'BEGIN{printf "%-16s area %10.0f um2  %7.1f kGE  seq %9.0f um2 (%4.1f%%)  DFF %s\n", d, a, a/0.798/1000, s, 100*s/a, ff}'
done
