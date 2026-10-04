# OpenROAD place and route of gdf_core with its SRAM macros on Nangate45
# (OpenROAD-flow-scripts platform files; fakeram45 macros of asic/macros).
# The same flow as pnr.tcl, with the macros read, placed in two columns at the
# left and right edges of the core (pins facing the logic) and covered by the
# macro grids of the platform power grid.  Environment:
#   NETLIST  Yosys netlist (asic/pnr/synth_mac.ys)   OUT  output directory
#   SDC      constraints (asic/pnr/gdf_mac.sdc)      PERIOD  clock period (ns)
#   UTIL     std-cell utilisation of the core outside the macros and halos (%)
#   MACRO_DIR  macro views (<name>/<name>.lef, .lib)  THREADS
set plat /root/work/pnr/orfs/flow/platforms/nangate45
set out  $::env(OUT)
set util $::env(UTIL)
set mdir $::env(MACRO_DIR)
set ::env(MIN_ROUTING_LAYER) metal2
set ::env(MIN_CLK_ROUTING_LAYER) metal4
set ::env(MAX_ROUTING_LAYER) metal10
set_thread_count $::env(THREADS)
proc stamp {msg} { puts "STAGE [clock format [clock seconds] -format %H:%M:%S] $msg" }

stamp "read"
read_lef $plat/lef/NangateOpenCellLibrary.tech.lef
read_lef $plat/lef/NangateOpenCellLibrary.macro.mod.lef
foreach f [lsort [glob $mdir/*/*.lef]] { read_lef $f }
read_liberty $plat/lib/NangateOpenCellLibrary_typical.lib
foreach f [lsort [glob $mdir/*/*.lib]] { read_liberty $f }
read_verilog $::env(NETLIST)
link_design gdf_core
read_sdc $::env(SDC)
source $plat/setRC.tcl
set_dont_use {TAPCELL_X1 FILLCELL_X1 AOI211_X1 OAI211_X1}
report_design_area

# ---------------------------------------------------------------- floorplan
stamp "floorplan"
set block [ord::get_db_block]
set dbu [$block getDbUnitsPerMicron]
set hx 10.0          ;# macro halo: std-cell rows cut around the macros (um)
set hy 5.6
set a_std 0.0
set a_mac 0.0
set macs {}
foreach inst [$block getInsts] {
  set m [$inst getMaster]
  set w [expr {double([$m getWidth]) / $dbu}]
  set h [expr {double([$m getHeight]) / $dbu}]
  if {[$m isBlock]} {
    lappend macs [list $inst [$m getName] $w $h]
    set a_mac [expr {$a_mac + ($w + 2 * $hx) * ($h + 2 * $hy)}]
  } else {
    set a_std [expr {$a_std + $w * $h}]
  }
}
set side [expr {sqrt($a_std / ($util / 100.0) + $a_mac)}]
# core side on the row and site grids
set side [expr {ceil($side / 2.8) * 2.8}]
set cs 10.0
set die [expr {$side + 2 * $cs}]
puts [format "MACROS %d, area %.0f um2 with halos; std cells %.0f um2; core %.1f um" \
  [llength $macs] $a_mac $a_std $side]
initialize_floorplan -die_area "0 0 $die $die" -core_area "$cs $cs [expr {$cs + $side}] [expr {$cs + $side}]" \
  -site FreePDK45_38x28_10R_NP_162NW_34O
source $plat/make_tracks.tcl

# macro columns: left (MY, pins on the right edge) and right (R0, pins on the
# left edge), bottom to top, as items spread evenly over the core height; an
# item is one macro or a stack of macros 2 halos apart (the four small
# PC-Wiener Q tables), so that no narrow rows of logic lie between them; the
# error tables are split between the two columns
proc by_master {macs pat} {
  set r {}
  foreach m $macs { if {[string match $pat [lindex $m 1]]} { lappend r $m } }
  return [lsort -index 0 -command {apply {{a b} {string compare [$a getName] [$b getName]}}} $r]
}
set luts [by_master $macs fakeram45_4096x7]
set nl [llength $luts]
set lmid [list [by_master $macs fakeram45_1r1w_64x26]]
foreach m [by_master $macs fakeram45_1r1w_34x240] { lappend lmid [list $m] }
set rmid {}
foreach m [by_master $macs fakeram45_1r1w_256x105] { lappend rmid [list $m] }
foreach m [by_master $macs fakeram45_1r1w_34x130] { lappend rmid [list $m] }
set lluts {}
foreach m [lrange $luts 0 [expr {$nl / 2 - 1}]] { lappend lluts [list $m] }
set rluts {}
foreach m [lrange $luts [expr {$nl / 2}] end] { lappend rluts [list $m] }
# MACRO_ORDER=center: the buffers and tables of each column between its error
# tables (the logic they attract spreads above and below them); else on top
if {[info exists ::env(MACRO_ORDER)] && $::env(MACRO_ORDER) eq "center"} {
  set left  [concat [lrange $lluts 0 1] $lmid [lrange $lluts 2 end]]
  set right [concat [lrange $rluts 0 1] $rmid [lrange $rluts 2 end]]
} else {
  set left  [concat $lluts $lmid]
  set right [concat $rluts $rmid]
}
# further macros (the class ROM of the ROM_MACRO variant): at the bottom of the
# core, centered, pins on the left edge
set extra [by_master $macs fakeram45_rom_*]
set nplaced [llength $extra]
foreach col [list $left $right] { foreach it $col { incr nplaced [llength $it] } }
if {$nplaced != [llength $macs]} {
  error "unplaced macros: [llength $macs] macros, $nplaced in columns"
}
# core box in microns; macro origins snap to the site grid (0.19 x 1.4 um)
set core [$block getCoreArea]
set cx0 [expr {double([$core xMin]) / $dbu}]
set cy0 [expr {double([$core yMin]) / $dbu}]
set cx1 [expr {double([$core xMax]) / $dbu}]
set cy1 [expr {double([$core yMax]) / $dbu}]
proc snap {v g} { return [expr {round($v / $g) * $g}] }
# the two macro columns: items spread over the core height with equal gaps,
# the macros of an item stacked two halos apart, pins facing the logic
foreach {col orient} [list $left MY $right R0] {
  set hsum 0.0
  foreach it $col {
    foreach m $it { set hsum [expr {$hsum + [lindex $m 3]}] }
    set hsum [expr {$hsum + 2 * $hy * ([llength $it] - 1)}]
  }
  set n [llength $col]
  set gap [expr {($cy1 - $cy0 - 2 * $hy - $hsum) / max(1, $n - 1)}]
  if {$gap < 2 * $hy} { error "macro column too tall: [format %.1f $hsum] um in [format %.1f [expr {$cy1 - $cy0}]] um" }
  puts [format "MACRO column %s: %d items, gap %.1f um" $orient $n $gap]
  set y [expr {$cy0 + $hy}]
  foreach it $col {
    foreach m $it {
      lassign $m inst master w h
      set x [expr {$orient eq "MY" ? $cx0 + $hx : $cx1 - $hx - $w}]
      set xs [expr {$cx0 + [snap [expr {$x - $cx0}] 0.19]}]
      set ys [expr {$cy0 + [snap [expr {$y - $cy0}] 1.4]}]
      $inst setOrient $orient
      $inst setLocation [expr {round($xs * $dbu)}] [expr {round($ys * $dbu)}]
      $inst setPlacementStatus FIRM
      puts [format "MACRO %-28s %-24s %s at (%.2f, %.2f) %.2f x %.2f" [$inst getName] $master $orient $xs $ys $w $h]
      set y [expr {$y + $h + 2 * $hy}]
    }
    set y [expr {$y - 2 * $hy + $gap}]
  }
}
# the ROM macro(s) at the bottom centre of the core
set x [expr {($cx0 + $cx1) / 2.0}]
foreach m $extra {
  lassign $m inst master w h
  set xs [expr {$cx0 + [snap [expr {$x - $w / 2.0 - $cx0}] 0.19]}]
  set ys [expr {$cy0 + [snap $hy 1.4]}]
  $inst setOrient R0
  $inst setLocation [expr {round($xs * $dbu)}] [expr {round($ys * $dbu)}]
  $inst setPlacementStatus FIRM
  puts [format "MACRO %-28s %-24s R0 at (%.2f, %.2f) %.2f x %.2f" [$inst getName] $master $xs $ys $w $h]
  set x [expr {$x + $w + 2 * $hx}]
}
# no rows inside the halos; pins, tap cells and the power grid of the platform
cut_rows -halo_width_x $hx -halo_width_y $hy
place_pins -hor_layers metal5 -ver_layers metal6 -min_distance 0.56
tapcell -distance 120 -tapcell_master TAPCELL_X1 -endcap_master TAPCELL_X1
source $plat/grid_strategy-M1-M4-M7.tcl
pdngen

# ---------------------------------------------------------------- placement
stamp "global placement"
global_placement -density [expr {$util / 100.0 + 0.10}] -routability_driven
estimate_parasitics -placement
stamp "repair design"
repair_design
repair_tie_fanout LOGIC0_X1/Z
repair_tie_fanout LOGIC1_X1/Z
stamp "detailed placement"
detailed_placement -max_displacement {500 100}
optimize_mirroring
check_placement
report_design_area
puts "PLACED_WNS [sta::worst_slack_cmd max]"

# ---------------------------------------------------------------- clock tree
stamp "cts"
clock_tree_synthesis -root_buf CLKBUF_X3 -buf_list {CLKBUF_X1 CLKBUF_X2 CLKBUF_X3} \
  -sink_clustering_enable
set_propagated_clock [all_clocks]
estimate_parasitics -placement
repair_clock_nets
detailed_placement
estimate_parasitics -placement
stamp "repair timing (cts)"
repair_timing -setup -repair_tns 100
repair_timing -hold -hold_margin [expr {[info exists ::env(HOLD_CTS)] ? $::env(HOLD_CTS) : 0.02}]
detailed_placement
check_placement
report_clock_skew
puts "CTS_WNS [sta::worst_slack_cmd max] HOLD [sta::worst_slack_cmd min]"
write_db $out/cts.odb

# ---------------------------------------------------------------- global route
stamp "global route"
source $plat/fastroute.tcl
# residual congestion is left to the detailed router (its DRC report decides)
global_route -guide_file $out/route.guide -congestion_iterations 50 \
  -congestion_report_file $out/congestion.rpt -allow_congestion
estimate_parasitics -global_routing
puts "GRT_WNS [sta::worst_slack_cmd max] HOLD [sta::worst_slack_cmd min]"
set hm [expr {[info exists ::env(HOLD_GRT)] ? $::env(HOLD_GRT) : 0.05}]
if {[info exists ::env(FULL_REROUTE)] && $::env(FULL_REROUTE)} {
  repair_design
  repair_timing -setup -repair_tns 100
  repair_timing -hold -hold_margin $hm
  detailed_placement -max_displacement {500 100}
  global_route -guide_file $out/route.guide -congestion_iterations 50 \
    -congestion_report_file $out/congestion2.rpt -allow_congestion
} else {
  global_route -start_incremental
  repair_design
  repair_timing -setup -repair_tns 100
  repair_timing -hold -hold_margin $hm
  detailed_placement
  global_route -end_incremental -guide_file $out/route.guide
}
estimate_parasitics -global_routing
puts "GRT2_WNS [sta::worst_slack_cmd max] HOLD [sta::worst_slack_cmd min]"
write_db $out/grt.odb

# ---------------------------------------------------------------- detailed route
stamp "detailed route"
detailed_route -output_drc $out/drc.rpt -bottom_routing_layer metal2 \
  -top_routing_layer metal10 -droute_end_iter 40 -verbose 1
filler_placement {FILLCELL_X32 FILLCELL_X16 FILLCELL_X8 FILLCELL_X4 FILLCELL_X2 FILLCELL_X1}
write_db $out/route.odb

# ---------------------------------------------------------------- sign-off reports
stamp "extraction"
define_process_corner -ext_model_index 0 X
extract_parasitics -ext_model_file $plat/rcx_patterns.rules
write_spef $out/gdf.spef
read_spef $out/gdf.spef
stamp "reports"
report_checks -path_delay max -group_count 5 -format full_clock_expanded \
  -fields {slew cap input_pins fanout} > $out/timing_max.rpt
report_checks -path_delay min -group_count 5 -format full_clock_expanded > $out/timing_min.rpt
report_clock_skew > $out/skew.rpt
report_design_area
puts "FINAL_WNS [sta::worst_slack_cmd max] TNS [sta::total_negative_slack_cmd max] HOLD [sta::worst_slack_cmd min]"
puts "CORE_AREA [ord::get_core_area] DIE_AREA [ord::get_die_area]"
set_power_activity -input -activity 0.2 -duty 0.5
report_power > $out/power_default.rpt
write_def $out/final.def
write_verilog $out/final.v
write_db $out/final.odb
stamp "done"
puts "PNR_DONE"
