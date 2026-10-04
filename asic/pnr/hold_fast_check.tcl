# Exact hold slack of the worst register-to-register paths at the fast corner
# (corners_mac.tcl setup).  Environment: RUN, SDC, PERIOD, MACRO_DIR, MACRO_CORNERS
set lib /mnt/g/AV2/asic/lib_corners
set run $::env(RUN)
set mdir $::env(MACRO_DIR)
define_corners fast
read_liberty -corner fast $lib/nangate45_fast.lib
foreach f [lsort [glob $mdir/*/*.lib]] {
  set n [file rootname [file tail $f]]
  read_liberty -corner fast $::env(MACRO_CORNERS)/${n}_fast.lib
}
read_db $run/route.odb
read_sdc $::env(SDC)
set_propagated_clock [all_clocks]
read_spef $run/gdf.spef
report_checks -path_delay min -corner fast -from [all_registers -clock_pins] -group_count 5 \
  -endpoint_count 1 -digits 4 -format end
report_checks -path_delay min -corner fast -from [all_registers -clock_pins] -group_count 1 \
  -digits 4 -fields {slew cap net}
