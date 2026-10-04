# Sign-off reports of a routed gdf_core block: loads route.odb and the
# extracted SPEF.  Environment: OUT (run directory), SDC, PERIOD, [VCD, SCOPE]
set plat /root/work/pnr/orfs/flow/platforms/nangate45
set out $::env(OUT)
read_db $out/route.odb
read_liberty $plat/lib/NangateOpenCellLibrary_typical.lib
read_sdc $::env(SDC)
set_propagated_clock [all_clocks]
read_spef $out/gdf.spef

report_checks -path_delay max -group_count 5 -format full_clock_expanded \
  -fields {slew cap input_pins fanout} > $out/timing_max.rpt
report_checks -path_delay min -group_count 5 -format full_clock_expanded > $out/timing_min.rpt
report_clock_skew > $out/skew.rpt
set wns [sta::worst_slack_cmd max]
set whs [sta::worst_slack_cmd min]
set tns [sta::total_negative_slack_cmd max]
puts "FINAL_WNS $wns TNS $tns HOLD $whs"
puts "FMAX_MHZ [expr {1000.0 / ($::env(PERIOD) - $wns * 1e9)}]"

# areas: standard cells (without fillers), core and die
set dbu [[ord::get_db_block] getDbUnitsPerMicron]
set cell_area 0.0
set n_cells 0
set n_ff 0
foreach inst [[ord::get_db_block] getInsts] {
  set m [$inst getMaster]
  set name [$m getName]
  if {[string match FILLCELL* $name]} { continue }
  set cell_area [expr {$cell_area + double([$m getWidth]) * [$m getHeight] / ($dbu * $dbu)}]
  incr n_cells
  if {[string match DFF* $name]} { incr n_ff }
}
set core [ord::get_db_core]
set die [[ord::get_db_block] getDieArea]
set core_area [expr {double([$core dx]) * [$core dy] / ($dbu * $dbu)}]
set die_area [expr {double([$die dx]) * [$die dy] / ($dbu * $dbu)}]
puts "CELL_AREA_UM2 $cell_area CELLS $n_cells FFS $n_ff"
puts "CORE_AREA_UM2 $core_area DIE_AREA_UM2 $die_area DIE [expr {double([$die dx]) / $dbu}] x [expr {double([$die dy]) / $dbu}] um"
puts "CELL_KGE [expr {$cell_area / 0.798 / 1000.0}] UTIL [expr {$cell_area / $core_area}]"

# power: vectorless (inputs toggle 20 %) and, if given, from a VCD
set_power_activity -input -activity 0.2 -duty 0.5
report_power > $out/power_vectorless.rpt
if {[info exists ::env(VCD)]} {
  read_vcd -scope $::env(SCOPE) $::env(VCD)
  report_power > $out/power_vcd.rpt
}
puts "REPORT_DONE"
