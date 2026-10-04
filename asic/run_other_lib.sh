#!/usr/bin/env bash
# Synthesis cross-check of the joint stage with chroma in another cell
# library (the recipe of run_all_r4.sh: Booth multipliers, memories as black
# boxes): the open SkyWater 130-nm high-density library, typical corner
# (asic/lib_other/sky130_fd_sc_hd__tt_025C_1v80.lib, from the OpenROAD flow
# scripts), with a delay target relaxed in proportion (8 ns).  Reports the
# cell area in NAND2 equivalents (sky130_fd_sc_hd__nand2_1 = 3.7536 um2).
# Usage: run_other_lib.sh          (output: /root/work/asic/x_sky130)
set -euo pipefail
LIB=/mnt/g/AV2/asic/lib_other/sky130_fd_sc_hd__tt_025C_1v80.lib
OUT=/root/work/asic/x_sky130; mkdir -p $OUT
D=${DELAY:-8000}
cat > $OUT/synth.ys <<EOF
read_verilog /mnt/g/AV2/rtl/gdf_core.v
blackbox gdf_ram_sdp gdf_ram_lut gdf_rom_pcw gdf_rom_sel
chparam -set MAXCH 1024 -set AW 10 -set MSTG 1 -set VS 1 -set PCW 1 -set LR 1 -set CH 1 gdf_core
hierarchy -check -top gdf_core
synth -top gdf_core -flatten -booth
dfflibmap -liberty $LIB
abc -D $D -liberty $LIB
opt_clean
tee -o $OUT/stat.txt stat -liberty $LIB
EOF
nice -n 10 /opt/yosys/bin/yosys -q -l $OUT/yosys.log -s $OUT/synth.ys > /dev/null 2>&1
a=$(grep "Chip area for module" $OUT/stat.txt | tail -1 | awk '{print $NF}')
ff=$(grep -cE "^ +sky130_fd_sc_hd__df" $OUT/stat.txt || true)
nff=$(grep -E "^ +sky130_fd_sc_hd__df" $OUT/stat.txt | awk '{s += $2} END {print s}')
awk -v a=$a -v n=$nff 'BEGIN{printf "sky130hd: %.0f um2 = %.1f kGE (NAND2_1 3.7536 um2), flip-flops %d\n", a, a/3.7536/1000, n}' | tee $OUT/summary.txt
grep -h "Delay =" $OUT/yosys.log | tail -1 | tee -a $OUT/summary.txt
