# List the failing setup endpoints of a routed self-test checkpoint, grouped
# by the hierarchy of the endpoint cell (to see which logic misses timing).
# Usage: vivado -mode batch -source fail_ends.tcl -tclargs <routed.dcp>
open_checkpoint [lindex $argv 0]
set paths [get_timing_paths -setup -max_paths 2000 -nworst 1 -slack_lesser_than 0]
puts "FAILING_PATHS [llength $paths]"
array set grp {}
foreach p $paths {
  set ep [get_property ENDPOINT_PIN $p]
  set sp [get_property STARTPOINT_PIN $p]
  regsub {/[^/]*$} $ep {} ec
  regsub {\[[0-9]+\]} $ec {[*]} ec
  regsub -all {_reg[^/]*$} $ec {_reg} ec
  regsub {/[^/]*$} $sp {} sc
  regsub {\[[0-9]+\]} $sc {[*]} sc
  regsub -all {_reg[^/]*$} $sc {_reg} sc
  set k "$sc -> $ec"
  if {[info exists grp($k)]} { incr grp($k) } else { set grp($k) 1 }
}
foreach k [lsort [array names grp]] { puts "GROUP $grp($k) $k" }
puts "FAIL_ENDS_DONE"
