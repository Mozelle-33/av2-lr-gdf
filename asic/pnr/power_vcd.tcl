# Post-layout power of a routed gdf_core from gate-level switching activity:
# routed database + extracted SPEF + VCD of the routed netlist (gl_sim.sh).
# Environment: OUT (run directory), SDC, PERIOD, VCD, SCOPE [, MACRO_DIR]
set plat /root/work/pnr/orfs/flow/platforms/nangate45
read_db $::env(OUT)/route.odb
read_liberty $plat/lib/NangateOpenCellLibrary_typical.lib
# SRAM macro models of a run with macros (pnr_mac.tcl)
if {[info exists ::env(MACRO_DIR)]} {
  foreach f [lsort [glob $::env(MACRO_DIR)/*/*.lib]] { read_liberty $f }
}
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
set rpt [expr {[info exists ::env(RPT)] ? $::env(RPT) : "power_vcd.rpt"}]
report_power > $::env(OUT)/$rpt
# optional per-instance power (power_by_function.py joins it with the
# function labels of layout_by_function.py)
if {[info exists ::env(INST_RPT)]} {
  report_power -instances [get_cells *] > $::env(OUT)/$::env(INST_RPT)
}
puts "POWER_VCD_DONE"
