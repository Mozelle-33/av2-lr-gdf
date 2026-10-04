# Power of a routed gdf_core over an activity window without the full
# per-instance report (which needs most of the memory): the totals by group
# (with the macros), the power of each macro and that of the instances of one
# function of layout_by_function.py (LABELS, LABEL), e.g. the chroma unit.
# Environment: OUT, SDC, PERIOD, VCD, SCOPE, RPT, MACRO_DIR, LABELS, LABEL
set plat /root/work/pnr/orfs/flow/platforms/nangate45
read_db $::env(OUT)/route.odb
read_liberty $plat/lib/NangateOpenCellLibrary_typical.lib
foreach f [lsort [glob $::env(MACRO_DIR)/*/*.lib]] { read_liberty $f }
read_sdc $::env(SDC)
# OpenSTA propagates activities from the roots of the timing graph and through
# registers only, so the logic fed by the macro outputs (the column buffers,
# tables) would keep no activity although the VCD annotates it: with the
# macro arcs disabled, the macro outputs are roots that take the VCD activity
if {[info exists ::env(MACRO_DIR)]} {
  set_disable_timing [get_cells -filter "ref_name =~ fakeram45_*" *]
}
set_propagated_clock [all_clocks]
read_spef $::env(OUT)/gdf.spef
read_vcd -scope $::env(SCOPE) $::env(VCD)
report_power
report_power > $::env(OUT)/$::env(RPT)
set macs [get_cells -filter "ref_name =~ fakeram45_*" *]
puts "macros: [llength $macs]"
report_power -instances $macs > $::env(OUT)/[file rootname $::env(RPT)]_macros.rpt
set names {}
set fh [open $::env(LABELS)]
while {[gets $fh line] >= 0} {
  # split, not lindex: keep the escaped brackets of the DEF names (\[ \])
  set parts [split [string trim $line] " "]
  if {[lindex $parts end] eq $::env(LABEL)} { lappend names [lindex $parts 0] }
}
close $fh
set cells [get_cells -quiet $names]
puts "$::env(LABEL) instances: [llength $names] labeled, [llength $cells] found"
report_power -instances $cells > $::env(OUT)/[file rootname $::env(RPT)]_$::env(LABEL).rpt
puts "POWER_VCD_DONE"
