# Multi-corner timing of a routed gdf_core with its SRAM macros: the Nangate45
# corner libraries of OpenSTA (asic/lib_corners) and the macro models scaled to
# the corners (asic/macros/scale_macro_lib.py); setup at the slow corner (0.95 V,
# 125 C), hold at the fast corner (1.25 V, 0 C) and both at the typical corner,
# with the parasitics of the extraction (gdf.spef) for every corner.  The
# paths from the bit-depth mode register (bd10, written only between segments)
# are reported without and with a two-cycle constraint, and the hold reports
# of corners_reg2reg.tcl cover the paths launched by registers.
# Environment: RUN (routed run directory), SDC, PERIOD, MACRO_DIR, MACRO_CORNERS
set lib /mnt/g/AV2/asic/lib_corners
set run $::env(RUN)
set mdir $::env(MACRO_DIR)
define_corners slow typ fast
read_liberty -corner slow $lib/nangate45_slow.lib
read_liberty -corner typ  $lib/nangate45_typ.lib
read_liberty -corner fast $lib/nangate45_fast.lib
foreach f [lsort [glob $mdir/*/*.lib]] {
  set n [file rootname [file tail $f]]
  read_liberty -corner slow $::env(MACRO_CORNERS)/${n}_slow.lib
  read_liberty -corner typ  $f
  read_liberty -corner fast $::env(MACRO_CORNERS)/${n}_fast.lib
}
read_db $run/route.odb
read_sdc $::env(SDC)
set_propagated_clock [all_clocks]
read_spef $run/gdf.spef

foreach c {slow typ fast} {
  report_checks -path_delay max -corner $c -group_count 1 > $run/corner_${c}_max.rpt
  report_checks -path_delay min -corner $c -group_count 1 > $run/corner_${c}_min.rpt
  report_checks -path_delay min -corner $c -slack_max 0 -group_count 100000 -endpoint_count 1 \
    -format end > $run/corner_${c}_min_viol.rpt
}
# hold of the paths launched by flip-flops (to flip-flops and macros); the
# macro-launched paths start with the clock-to-output delay of the macro
foreach c {slow typ fast} {
  report_checks -path_delay min -corner $c -from [all_registers -clock_pins] -group_count 1 > $run/corner_${c}_min_r2r.rpt
  report_checks -path_delay min -corner $c -from [all_registers -clock_pins] -slack_max 0 \
    -group_count 100000 -endpoint_count 1 -format end > $run/corner_${c}_min_r2r_viol.rpt
}
# the bit-depth mode register (bd10) is written only between segments, at least
# two cycles before a segment uses it: two-cycle paths
set bdq [get_pins -of_objects [get_nets -hierarchical *bd10*] -filter "direction == output"]
set bdc [get_cells -of_objects $bdq]
puts "mode register cells: [llength $bdc]"
set_multicycle_path 2 -setup -from $bdc
set_multicycle_path 1 -hold -from $bdc
foreach c {slow typ fast} {
  report_checks -path_delay max -corner $c -group_count 1 > $run/corner_${c}_max_mcp.rpt
  report_checks -path_delay min -corner $c -from [all_registers -clock_pins] -group_count 1 > $run/corner_${c}_min_r2r_mcp.rpt
}
puts "CORNERS_DONE"
