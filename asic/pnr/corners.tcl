# Multi-corner timing of a routed gdf_core with the Nangate45 corner libraries
# of OpenSTA (asic/lib_corners): setup at the slow corner (0.95 V, 125 C), hold
# at the fast corner (1.25 V, 0 C) and both at the typical corner (1.10 V,
# 25 C), with the parasitics of the extraction (gdf.spef) for every corner.
# The datapath reports declare the paths from the bit-depth mode register
# (bd10, written only between segments) false, as a multicycle constraint would.
# (find_timing_paths -corner crashed OpenROAD v2.0-17598; report_checks works.)
# Environment: RUN (routed run directory), SDC, PERIOD
set lib /mnt/g/AV2/asic/lib_corners
set run $::env(RUN)
define_corners slow typ fast
read_liberty -corner slow $lib/nangate45_slow.lib
read_liberty -corner typ  $lib/nangate45_typ.lib
read_liberty -corner fast $lib/nangate45_fast.lib
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
set bdq [get_pins -of_objects [get_nets -hierarchical *bd10*] -filter "direction == output"]
set_false_path -from [get_cells -of_objects $bdq]
foreach c {slow typ} {
  report_checks -path_delay max -corner $c -group_count 1 > $run/corner_${c}_max_dp.rpt
}
puts "CORNERS_DONE"
