#!/usr/bin/env bash
# Area of the signed multipliers of the chroma LR unit (gdf_lrc S2), Yosys
# Booth + abc -D 2500, Nangate45 typical: 12x7 (taps 0-1), 12x6 (2-3),
# 12x5 (4-5), 11x5 (6-9), 11x4 (10-17); per sample 2+2+2+4+8 = 18 products.
set -e
W=/root/work/asic/mul_area; mkdir -p $W
LIB=/root/work/asic/NangateOpenCellLibrary_typical.lib
for ab in 12x7 12x6 12x5 11x5 11x4; do
  a=${ab%x*}; b=${ab#*x}
  cat > $W/m_$ab.v <<EOF
module m (input clk, input signed [$((a-1)):0] x, input signed [$((b-1)):0] y, output reg signed [$((a+b-1)):0] p);
  reg signed [$((a-1)):0] xq; reg signed [$((b-1)):0] yq;
  always @(posedge clk) begin xq <= x; yq <= y; p <= xq * yq; end
endmodule
EOF
  /opt/yosys/bin/yosys -q -p "read_verilog $W/m_$ab.v; synth -top m -flatten -booth; dfflibmap -liberty $LIB; abc -D 2500 -liberty $LIB; opt_clean; tee -o $W/s_$ab.txt stat -liberty $LIB" > /dev/null
  tot=$(grep "Chip area" $W/s_$ab.txt | awk '{print $NF}')
  seq=$(grep "sequential elements" $W/s_$ab.txt | awk '{print $(NF-1)}')
  awk -v n=$ab -v t=$tot -v s=$seq 'BEGIN{printf "%s total %.1f um2 seq %.1f comb %.1f um2 = %.3f kGE\n", n, t, s, t-s, (t-s)/0.798/1000}'
done
