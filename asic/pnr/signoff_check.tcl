# Re-check the timing of a routed gdf_core against the current gdf.sdc (e.g.,
# after adding a port to the I/O lists) and list what the SDC leaves
# unconstrained.  Environment: RUN (routed run directory), SDC, PERIOD
set plat /root/work/pnr/orfs/flow/platforms/nangate45
set run $::env(RUN)
read_db $run/route.odb
read_liberty $plat/lib/NangateOpenCellLibrary_typical.lib
if {[info exists ::env(MACRO_DIR)]} {
  foreach f [lsort [glob $::env(MACRO_DIR)/*/*.lib]] { read_liberty $f }
}
read_sdc $::env(SDC)
set_propagated_clock [all_clocks]
read_spef $run/gdf.spef

check_setup -verbose -unconstrained_endpoints -multiple_clock -no_clock -loops -generated_clocks
report_checks -path_delay max -from [get_ports in_lr*] -format full_clock_expanded
report_checks -path_delay min -from [get_ports in_lr*] -format full_clock_expanded
report_checks -path_delay max -group_count 5 -format full_clock_expanded   -fields {slew cap input_pins fanout} > $run/timing_max.rpt
report_checks -path_delay min -group_count 5 -format full_clock_expanded > $run/timing_min.rpt
set wns [sta::worst_slack_cmd max]
set whs [sta::worst_slack_cmd min]
set tns [sta::total_negative_slack_cmd max]
puts "SIGNOFF_WNS $wns TNS $tns HOLD $whs"
puts "FMAX_MHZ [expr {1000.0 / ($::env(PERIOD) - $wns * 1e9)}]"
puts "SIGNOFF_DONE"
