# Hold ECO of a run of pnr_mac.tcl: from its checkpoint after global routing
# (grt.odb), hold repair at the typical corner of the flow and at the fast
# corner of asic/lib_corners (1.25 V, 0 C; a flip-flop-to-flip-flop path had
# missed hold there by 4 ps), then global and detailed routing, extraction and
# the reports of pnr_mac.tcl.  The slow corner is left out: its hold checks of
# the block inputs depend on the absolute input delay of the SDC.  Both corners
# use the OpenSTA libraries (the same cells); the sign-off reports at the
# typical corner of the flow come from signoff_check.tcl afterwards.
# Environment: OUT (run directory), SDC, PERIOD, MACRO_DIR, MACRO_CORNERS, THREADS
set plat /root/work/pnr/orfs/flow/platforms/nangate45
set lib  /mnt/g/AV2/asic/lib_corners
set out  $::env(OUT)
set mdir $::env(MACRO_DIR)
set ::env(MIN_ROUTING_LAYER) metal2
set ::env(MIN_CLK_ROUTING_LAYER) metal4
set ::env(MAX_ROUTING_LAYER) metal10
set_thread_count $::env(THREADS)
proc stamp {msg} { puts "STAGE [clock format [clock seconds] -format %H:%M:%S] $msg" }

stamp "read"
define_corners typ fast
read_liberty -corner typ  $lib/nangate45_typ.lib
read_liberty -corner fast $lib/nangate45_fast.lib
foreach f [lsort [glob $mdir/*/*.lib]] {
  set n [file rootname [file tail $f]]
  read_liberty -corner typ  $f
  read_liberty -corner fast $::env(MACRO_CORNERS)/${n}_fast.lib
}
read_db $out/grt.odb
read_sdc $::env(SDC)
source $plat/setRC.tcl
set_dont_use {TAPCELL_X1 FILLCELL_X1 AOI211_X1 OAI211_X1}
set_propagated_clock [all_clocks]
estimate_parasitics -placement

stamp "hold repair (typ, fast)"
report_checks -path_delay min -corner fast -from [all_registers -clock_pins] -group_count 3 \
  -endpoint_count 1 -digits 4 -format end
set ninst0 [llength [[ord::get_db_block] getInsts]]
repair_timing -hold -hold_margin [expr {[info exists ::env(HOLD_ECO)] ? $::env(HOLD_ECO) : 0.01}]
puts "ECO inserted [expr {[llength [[ord::get_db_block] getInsts]] - $ninst0}] instances"
detailed_placement
check_placement
report_checks -path_delay min -corner fast -from [all_registers -clock_pins] -group_count 3 \
  -endpoint_count 1 -digits 4 -format end

stamp "global route"
source $plat/fastroute.tcl
global_route -guide_file $out/route.guide -congestion_iterations 50 \
  -congestion_report_file $out/congestion_eco.rpt -allow_congestion
estimate_parasitics -global_routing
puts "ECO_GRT_WNS [sta::worst_slack_cmd max] HOLD [sta::worst_slack_cmd min]"
write_db $out/grt_eco.odb

stamp "detailed route"
detailed_route -output_drc $out/drc.rpt -bottom_routing_layer metal2 \
  -top_routing_layer metal10 -droute_end_iter 40 -verbose 1
filler_placement {FILLCELL_X32 FILLCELL_X16 FILLCELL_X8 FILLCELL_X4 FILLCELL_X2 FILLCELL_X1}
write_db $out/route.odb

stamp "extraction"
define_process_corner -ext_model_index 0 X
extract_parasitics -ext_model_file $plat/rcx_patterns.rules
write_spef $out/gdf.spef
read_spef $out/gdf.spef
stamp "reports"
report_checks -path_delay max -corner typ -group_count 5 -format full_clock_expanded \
  -fields {slew cap input_pins fanout} > $out/timing_max.rpt
report_checks -path_delay min -corner typ -group_count 5 -format full_clock_expanded > $out/timing_min.rpt
report_checks -path_delay min -corner fast -from [all_registers -clock_pins] -group_count 3 \
  -endpoint_count 1 -digits 4 -format end
report_clock_skew > $out/skew.rpt
report_design_area
puts "FINAL_WNS [sta::worst_slack_cmd max] TNS [sta::total_negative_slack_cmd max] HOLD [sta::worst_slack_cmd min]"
puts "CORE_AREA [ord::get_core_area] DIE_AREA [ord::get_die_area]"
write_def $out/final.def
write_verilog $out/final.v
write_db $out/final.odb
stamp "done"
puts "PNR_DONE"
