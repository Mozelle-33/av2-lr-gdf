#!/usr/bin/env bash
# All ASIC variants in parallel: {proposed, FULL} x {array, Booth} multipliers.
cd /root/work/asic
for f in 0 1; do for b in 0 1; do
  bash /mnt/g/AV2/asic/run_asic.sh $f ${1:-2500} 1 $b > run_f${f}_b${b}.txt 2>&1 &
done; done
wait
for f in 0 1; do for b in 0 1; do echo "FULL=$f booth=$b: $(grep -v Warning run_f${f}_b${b}.txt | tr '\n' ' ')"; done; done
