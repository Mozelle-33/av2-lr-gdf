# Non-project build of the on-board self-test.
# Usage: vivado -mode batch -source build.tcl -tclargs <romdir> [clk_div] [tag] [fip] [vs] [lr] [ch] [strat]
#   romdir: directory with cmd.hex, in.hex, rom_params.vh (tools/make_rom.py)
#   clk_div: MMCM CLKOUT0 divide (VCO 1000 MHz), default 4.0 -> 250 MHz
#   vs: 1 = column-major core (the ROM must be built with make_rom.py --vs)
#   lr: 1 = joint LR/GDF core (vs = 1; ROM from tools/make_rom_joint.py)
#   ch: 1 = with the chroma LR (lr = 1; ROM from tools/make_rom_joint.py --ch)
#   strat: explore = place ExtraTimingOpt, route AggressiveExplore
set here [file dirname [file normalize [info script]]]
set root [file normalize $here/../..]
lassign $argv romdir div tag fip vs lr ch strat
if {$fip eq ""} { set fip 0 }
if {$vs eq ""} { set vs 0 }
if {$lr eq ""} { set lr 0 }
if {$ch eq ""} { set ch 0 }
if {$div eq ""} { set div 4.0 }
if {$tag eq ""} { set tag "d$div" }
set part xc7k325tffg900-1
set out $here/out_$tag
file mkdir $out
foreach f [concat {rom_params.vh manifest.json} [glob -tails -directory $romdir rom_*_*.hex]] {
  file copy -force $romdir/$f $out/$f
}
if {$lr} {
  # class and filter-selector ROM images of the joint core
  file copy -force $root/rtl/pcw_class.hex $out/pcw_class.hex
  file copy -force $root/rtl/pcw_sel.hex $out/pcw_sel.hex
}
cd $out

read_verilog [list $root/rtl/gdf_core.v $root/rtl/gdf_selftest.v $here/selftest_top.v]
read_xdc $here/selftest.xdc
synth_design -top selftest_top -part $part -include_dirs $out -generic CLK_DIV=$div -generic FIP=$fip -generic VS=$vs -generic LR=$lr -generic CH=$ch
report_utilization -file $out/synth_util.rpt
opt_design
if {$strat eq "explore"} {
  place_design -directive ExtraTimingOpt
} else {
  place_design
}
phys_opt_design -directive AggressiveExplore
if {$strat eq "explore"} {
  route_design -directive AggressiveExplore
} else {
  route_design
}
write_checkpoint -force $out/routed.dcp
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "RESULT selftest tag=$tag div=$div WNS=$wns"
report_timing_summary -max_paths 20 -file $out/timing.rpt
report_utilization -file $out/util.rpt
report_utilization -hierarchical -file $out/util_hier.rpt
report_power -file $out/power.rpt
report_drc -file $out/drc.rpt
write_bitstream -force $out/selftest.bit
puts "BUILD_DONE tag=$tag"
