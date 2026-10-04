#!/usr/bin/env bash
# Self-test ROM for the column-major FPGA core (VS=1, FIP=1) with the same
# content as rom_v2_fip, then a 2-loop Verilator run of the self-test.
set -euo pipefail
cd /mnt/g/AV2/tools
python3 make_rom.py /root/work/rom_v2_fipvs --dumps /root/work/dumps/*.gdfdump /root/work/dumps_lr/*.gdfdump \
  --stress /root/work/stress_stripe.bin --in-budget 46000 --sets 4 --units 8 --stress-units 8 --fip --vs \
  2>/root/work/rom_v2_fipvs.log | grep -E '"segments"|"samples"|pass_cycles|cmd_words|in_words'
cmp -s <(sort /root/work/rom_v2_fip/in.hex) <(sort /root/work/rom_v2_fipvs/in.hex) && echo "same input words (reordered)"
cd /root/work && FIP=1 VS=1 nice -n 5 bash /mnt/g/AV2/scripts/sim_selftest.sh /root/work/rom_v2_fipvs 2 0
cd /root/work && FIP=1 VS=1 nice -n 5 bash /mnt/g/AV2/scripts/sim_selftest.sh /root/work/rom_v2_fipvs 1 1
echo ROM_VS_DONE
