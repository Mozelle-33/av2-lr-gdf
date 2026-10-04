# Hold of the register-to-register paths of a routed gdf_core at the three
# corners of asic/lib_corners (the block-input paths depend on the input
# timing of the surrounding design, given as one absolute delay in gdf.sdc).
# Environment: RUN, SDC, PERIOD
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
  report_checks -path_delay min -corner $c -from [all_registers -clock_pins] -group_count 1 > $run/corner_${c}_min_r2r.rpt
  report_checks -path_delay min -corner $c -from [all_registers -clock_pins] -slack_max 0 \
    -group_count 100000 -endpoint_count 1 -format end > $run/corner_${c}_min_r2r_viol.rpt
}
puts "R2R_DONE"
