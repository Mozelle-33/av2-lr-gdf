#!/usr/bin/env bash
# Probe the same named flip-flop nets in the 720p power windows of the logic-only
# layout (joint_ch_u55_r5) and of the layout with macros (joint_ch_m4).
P=/mnt/g/AV2/asic/pnr
NETS='g_col.vwin\[6\]\[220\] g_col.vwin\[2\]\[8\] g_col.g_pcw.g_lr.ltop dsrc_f\[1288\]'
export NETS
R=/root/work/pnr/joint_ch_u55_r5
OUT=$R SDC=$P/gdf.sdc PERIOD=2.5 VCD=$R/gl/ksch_b2b20k_pins.vcd SCOPE=TOP/gdf_core/u_pnr \
  openroad -no_init -exit $P/probe_flops.tcl > /root/work/pnr/probe_r5.log 2>&1 &
R=/root/work/pnr/joint_ch_m4
OUT=$R SDC=$P/gdf_mac.sdc PERIOD=2.5 VCD=$R/gl/ksch_b2b20k_pins.vcd SCOPE=TOP/gdf_core MACRO_DIR=/root/work/macros_m4 \
  openroad -no_init -exit $P/probe_flops.tcl > /root/work/pnr/probe_m4.log 2>&1 &
wait
