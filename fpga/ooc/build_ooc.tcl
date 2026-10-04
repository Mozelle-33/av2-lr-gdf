# Out-of-context implementation of gdf_core for resource / Fmax reporting.
# Usage: vivado -mode batch -source build_ooc.tcl -tclargs <part> <period_ns> <maxch> <aw> <tag> [full]
set here [file dirname [file normalize [info script]]]
set root [file normalize $here/../..]
# optional 8th argument: extra generics, e.g. "MACF=0 IDXF=1 LA=0"; 9th: strat =
# explore (place ExtraTimingOpt, route AggressiveExplore) for a run that
# misses timing by a few picoseconds with the default directives
lassign $argv part period maxch aw tag full fip extra strat
if {$tag eq ""} { set tag "${part}_${period}ns_ch${maxch}" }
if {$full eq ""} { set full 0 }
if {$fip eq ""} { set fip 0 }
set gen [list -generic MAXCH=$maxch -generic AW=$aw -generic FULL=$full -generic FIP=$fip]
foreach g $extra { lappend gen -generic $g }
set out $here/out_$tag
file mkdir $out

read_verilog $root/rtl/gdf_core.v
set xdc $out/clk.xdc
set fh [open $xdc w]
puts $fh "create_clock -period $period -name clk \[get_ports clk\]"
close $fh
read_xdc -mode out_of_context $xdc

synth_design -top gdf_core -part $part -mode out_of_context {*}$gen -flatten_hierarchy rebuilt
report_utilization -file $out/synth_util.rpt
opt_design
if {$strat eq "explore"} { place_design -directive ExtraTimingOpt } else { place_design }
# (post-route phys_opt crashed Vivado 2026.1.1 once; optimise after placement only)
phys_opt_design -directive AggressiveExplore
if {$strat eq "explore"} { route_design -directive AggressiveExplore } else { route_design }
write_checkpoint -force $out/routed.dcp
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "RESULT tag=$tag part=$part period=$period full=$full WNS=$wns"
report_utilization -file $out/util.rpt
report_utilization -hierarchical -file $out/util_hier.rpt
report_timing_summary -max_paths 20 -file $out/timing.rpt
report_power -file $out/power.rpt
report_design_analysis -logic_level_distribution -file $out/levels.rpt
# endpoint summary of the 2000 worst paths
set fh [open $out/worst_endpoints.txt w]
foreach p [get_timing_paths -max_paths 2000 -nworst 1 -setup] {
  puts $fh "[get_property SLACK $p] [get_property STARTPOINT_PIN $p] -> [get_property ENDPOINT_PIN $p]"
}
close $fh
puts "REPORTS_DONE tag=$tag"
