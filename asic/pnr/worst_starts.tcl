# Worst setup paths of a routed gdf_core, one per endpoint, with the net that
# their startpoint flip-flop drives (to find quasi-static configuration
# registers or high-fanout sources on the critical paths).
# Environment: RUN (routed run directory), SDC, PERIOD, N (paths, default 400)
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
set n [expr {[info exists ::env(N)] ? $::env(N) : 400}]
set fh [open $run/worst_starts.txt w]
foreach path [find_timing_paths -path_delay max -group_count $n -endpoint_count 1 -sort_by_slack] {
  set sp [get_property $path startpoint]
  set ep [get_property $path endpoint]
  set spn [get_full_name $sp]
  set qn ""
  if {[get_property $sp is_port]} {
    set qn $spn
  } else {
    set inst [get_property $sp full_name]
    set inst [string range $inst 0 [expr {[string last / $inst] - 1}]]
    set qp [get_pins -quiet $inst/Q]
    if {$qp ne ""} { set qn [get_full_name [get_nets -of_objects $qp]] }
  }
  set epn [get_full_name [get_nets -of_objects $ep]]
  puts $fh "[format %.3f [expr {[get_property $path slack] * 1e9}]] $qn -> $epn"
}
close $fh
puts "WORST_STARTS_DONE"
