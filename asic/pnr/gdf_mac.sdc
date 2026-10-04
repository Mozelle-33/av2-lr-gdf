# Timing constraints for gdf_core with its SRAM macros (Nangate45, typical
# corner): the macros are cells of the netlist, timed by their Liberty models
# (asic/macros/gen_gdf_macros.py), so only the block I/O are constrained.
set period $::env(PERIOD)
create_clock -name clk -period $period [get_ports clk]
set_clock_uncertainty 0.05 [get_clocks clk]

set core_in  [get_ports {rst cfg_we cfg_addr* cfg_wdata* seg_start seg_h* seg_nch* in_valid in_data* in_tskip in_lr* in_gdf in_c_data* in_c_lr*}]
set core_out [get_ports {busy in_ready underrun out_valid out_band* out_group* out_err* out_corr* out_pcw* out_y* out_c_valid out_c_row* out_c_strip* out_c_y*}]

# block I/O: 20 % of the period on each side
set_input_delay  [expr 0.2 * $period] -clock clk $core_in
set_output_delay [expr 0.2 * $period] -clock clk $core_out

set_driving_cell -lib_cell BUF_X2 -pin Z $core_in
set_load 0.005 [all_outputs]
