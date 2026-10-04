# Group failing setup endpoints of a routed checkpoint by hierarchy.
# Usage: vivado -mode batch -source fail_groups.tcl -tclargs <routed.dcp>
open_checkpoint [lindex $argv 0]
set paths [get_timing_paths -setup -max_paths 30000 -nworst 1 -slack_lesser_than 0]
array set cnt {}
array set worst {}
foreach p $paths {
  set e [get_property ENDPOINT_PIN $p]
  set s [get_property STARTPOINT_PIN $p]
  regsub -all {\[[0-9]+\]} $e {} e
  regsub -all {\[[0-9]+\]} $s {} s
  set ek [join [lrange [split $e /] 0 2] /]
  set sk [join [lrange [split $s /] 0 2] /]
  set k "$sk -> $ek"
  if {![info exists cnt($k)]} { set cnt($k) 0; set worst($k) 0 }
  incr cnt($k)
  set sl [get_property SLACK $p]
  if {$sl < $worst($k)} { set worst($k) $sl }
}
set rows {}
foreach k [array names cnt] { lappend rows [list $cnt($k) $worst($k) $k] }
foreach r [lsort -integer -decreasing -index 0 $rows] { puts "GROUP [lindex $r 0] worst=[lindex $r 1] [lindex $r 2]" }
puts "TOTAL [llength $paths]"
