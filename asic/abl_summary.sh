#!/usr/bin/env bash
# Summary of the ablation syntheses (Nangate45, NAND2_X1 = 0.798 um^2).
cd /root/work/asic
for d in abl_m*; do
  a=$(grep "Chip area for module" $d/stat.txt | tail -1 | awk '{print $NF}')
  ff=$(grep -E "^ +DFF_X1 " $d/stat.txt | tail -1 | awk '{print $2}')
  dl=$(grep -h "Delay =" $d/yosys.log | tail -1 | sed -E 's/.*Delay = *([0-9.]+) ps.*/\1/')
  awk -v d=$d -v a=$a -v ff=$ff -v dl=$dl 'BEGIN{printf "%-16s %10.0f um2 %7.1f kGE  DFF %6d  delay %s ps\n", d, a, a/0.798/1000, ff, dl}'
done
