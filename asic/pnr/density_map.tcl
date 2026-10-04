# Cell density of a placed run in 50-um bins (top bins), and the location of the
# loads of the PC-Wiener class-ROM address nets (plut) and of the Q-table outputs.
# Environment: DB (odb file)
read_db $::env(DB)
set block [ord::get_db_block]
set dbu [$block getDbUnitsPerMicron]
array set area {}
foreach inst [$block getInsts] {
  set m [$inst getMaster]
  if {[$m isBlock]} { continue }
  if {[string match FILLCELL* [$m getName]] || [string match TAPCELL* [$m getName]]} { continue }
  set bb [$inst getBBox]
  set x [expr {int(([$bb xMin] + [$bb xMax]) / 2.0 / $dbu / 50)}]
  set y [expr {int(([$bb yMin] + [$bb yMax]) / 2.0 / $dbu / 50)}]
  set k "$x,$y"
  set a [expr {double([$m getWidth]) * [$m getHeight] / $dbu / $dbu}]
  if {[info exists area($k)]} { set area($k) [expr {$area($k) + $a}] } else { set area($k) $a }
}
set l {}
foreach k [array names area] { lappend l [list $k $area($k)] }
set l [lsort -real -decreasing -index 1 $l]
puts "top bins (50 um, x,y in units of 50 um): cell area / 2500 um2"
foreach e [lrange $l 0 14] { puts [format "  %-8s %.2f" [lindex $e 0] [expr {[lindex $e 1] / 2500.0}]] }
# loads of the class-ROM address and of the Q-table outputs
foreach pat {*u_pcw.plut* *u_pcw.ql_b*} {
  set xs {}; set ys {}
  foreach net [$block getNets] {
    if {![string match $pat [$net getName]]} { continue }
    foreach it [$net getITerms] {
      if {[$it isOutputSignal]} { continue }
      set bb [[$it getInst] getBBox]
      lappend xs [expr {[$bb xMin] / double($dbu)}]
      lappend ys [expr {[$bb yMin] / double($dbu)}]
    }
  }
  if {[llength $xs]} {
    set xs [lsort -real $xs]; set ys [lsort -real $ys]
    set n [llength $xs]
    puts [format "%s: %d loads, x median %.0f (%.0f..%.0f), y median %.0f (%.0f..%.0f)" $pat $n \
      [lindex $xs [expr {$n/2}]] [lindex $xs 0] [lindex $xs end] [lindex $ys [expr {$n/2}]] [lindex $ys 0] [lindex $ys end]]
  }
}
