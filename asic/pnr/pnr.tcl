# OpenROAD place and route of the gdf_core logic block on Nangate45
# (OpenROAD-flow-scripts platform files).  Environment:
#   NETLIST  Yosys netlist (asic/pnr/synth_pnr.ys)   OUT  output directory
#   SDC      constraints (asic/pnr/gdf.sdc)          PERIOD  clock period (ns)
#   UTIL     core utilisation (%)                    THREADS
set plat /root/work/pnr/orfs/flow/platforms/nangate45
set out  $::env(OUT)
set util $::env(UTIL)
set ::env(MIN_ROUTING_LAYER) metal2
set ::env(MIN_CLK_ROUTING_LAYER) metal4
set ::env(MAX_ROUTING_LAYER) metal10
set_thread_count $::env(THREADS)
proc stamp {msg} { puts "STAGE [clock format [clock seconds] -format %H:%M:%S] $msg" }

stamp "read"
read_lef $plat/lef/NangateOpenCellLibrary.tech.lef
read_lef $plat/lef/NangateOpenCellLibrary.macro.mod.lef
read_liberty $plat/lib/NangateOpenCellLibrary_typical.lib
read_verilog $::env(NETLIST)
link_design gdf_core
read_sdc $::env(SDC)
source $plat/setRC.tcl
set_dont_use {TAPCELL_X1 FILLCELL_X1 AOI211_X1 OAI211_X1}
report_design_area

# ---------------------------------------------------------------- floorplan
stamp "floorplan"
initialize_floorplan -utilization $util -aspect_ratio 1.0 -core_space 10.0 \
  -site FreePDK45_38x28_10R_NP_162NW_34O
source $plat/make_tracks.tcl
place_pins -hor_layers metal5 -ver_layers metal6 -min_distance 0.56
tapcell -distance 120 -tapcell_master TAPCELL_X1 -endcap_master TAPCELL_X1
source $plat/grid_strategy-M1-M4-M7.tcl
pdngen

# ---------------------------------------------------------------- placement
stamp "global placement"
global_placement -density [expr {$util / 100.0 + 0.10}] -routability_driven
estimate_parasitics -placement
stamp "repair design"
repair_design
repair_tie_fanout LOGIC0_X1/Z
repair_tie_fanout LOGIC1_X1/Z
stamp "detailed placement"
detailed_placement -max_displacement {500 100}
optimize_mirroring
check_placement
report_design_area
puts "PLACED_WNS [sta::worst_slack_cmd max]"

# ---------------------------------------------------------------- clock tree
stamp "cts"
clock_tree_synthesis -root_buf CLKBUF_X3 -buf_list {CLKBUF_X1 CLKBUF_X2 CLKBUF_X3} \
  -sink_clustering_enable
set_propagated_clock [all_clocks]
estimate_parasitics -placement
repair_clock_nets
detailed_placement
estimate_parasitics -placement
stamp "repair timing (cts)"
repair_timing -setup -repair_tns 100
repair_timing -hold -hold_margin [expr {[info exists ::env(HOLD_CTS)] ? $::env(HOLD_CTS) : 0.02}]
detailed_placement
check_placement
report_clock_skew
puts "CTS_WNS [sta::worst_slack_cmd max] HOLD [sta::worst_slack_cmd min]"
write_db $out/cts.odb

# ---------------------------------------------------------------- global route
stamp "global route"
source $plat/fastroute.tcl
global_route -guide_file $out/route.guide -congestion_iterations 50 \
  -congestion_report_file $out/congestion.rpt
estimate_parasitics -global_routing
puts "GRT_WNS [sta::worst_slack_cmd max] HOLD [sta::worst_slack_cmd min]"
# post-global-route repair with routed parasitics (hold margin covers the
# detailed-routing detours), then incremental re-route
set hm [expr {[info exists ::env(HOLD_GRT)] ? $::env(HOLD_GRT) : 0.05}]
if {[info exists ::env(FULL_REROUTE)] && $::env(FULL_REROUTE)} {
  # the incremental router crashed on the thousands of hold buffers of the
  # joint LR/GDF core: repair, legalize, then route all nets again
  repair_design
  repair_timing -setup -repair_tns 100
  repair_timing -hold -hold_margin $hm
  detailed_placement -max_displacement {500 100}
  global_route -guide_file $out/route.guide -congestion_iterations 50
} else {
  global_route -start_incremental
  repair_design
  repair_timing -setup -repair_tns 100
  repair_timing -hold -hold_margin $hm
  detailed_placement
  global_route -end_incremental -guide_file $out/route.guide
}
estimate_parasitics -global_routing
puts "GRT2_WNS [sta::worst_slack_cmd max] HOLD [sta::worst_slack_cmd min]"
write_db $out/grt.odb

# ---------------------------------------------------------------- detailed route
stamp "detailed route"
detailed_route -output_drc $out/drc.rpt -bottom_routing_layer metal2 \
  -top_routing_layer metal10 -droute_end_iter 40 -verbose 1
filler_placement {FILLCELL_X32 FILLCELL_X16 FILLCELL_X8 FILLCELL_X4 FILLCELL_X2 FILLCELL_X1}
write_db $out/route.odb

# ---------------------------------------------------------------- sign-off reports
stamp "extraction"
define_process_corner -ext_model_index 0 X
extract_parasitics -ext_model_file $plat/rcx_patterns.rules
write_spef $out/gdf.spef
read_spef $out/gdf.spef
stamp "reports"
report_checks -path_delay max -group_count 5 -format full_clock_expanded \
  -fields {slew cap input_pins fanout} > $out/timing_max.rpt
report_checks -path_delay min -group_count 5 -format full_clock_expanded > $out/timing_min.rpt
report_clock_skew > $out/skew.rpt
report_design_area
puts "FINAL_WNS [sta::worst_slack_cmd max] TNS [sta::total_negative_slack_cmd max] HOLD [sta::worst_slack_cmd min]"
puts "CORE_AREA [ord::get_core_area] DIE_AREA [ord::get_die_area]"
set_power_activity -input -activity 0.2 -duty 0.5
report_power > $out/power_default.rpt
write_def $out/final.def
write_verilog $out/final.v
write_db $out/final.odb
stamp "done"
puts "PNR_DONE"
