# read_vcd of a small VCD (vcd_probe_small.py) on a routed run, then the
# activities and power of the probed flip-flops, without and with the macro
# outputs as activity sources (set_disable_timing clk -> rd_out).
# Environment: OUT, SDC, VCD, SCOPE, MACRO_DIR, INSTS
set plat /root/work/pnr/orfs/flow/platforms/nangate45
read_db $::env(OUT)/route.odb
read_liberty $plat/lib/NangateOpenCellLibrary_typical.lib
foreach f [lsort [glob $::env(MACRO_DIR)/*/*.lib]] { read_liberty $f }
read_sdc $::env(SDC)
set_propagated_clock [all_clocks]
read_vcd -scope $::env(SCOPE) $::env(VCD)
proc probe {tag} {
  set cb [get_cells -filter "ref_name =~ fakeram45_1r1w_34x240" *]
  report_power -instances $cb -digits 6
  foreach b {0 100 239} {
    set p [get_pins -quiet "[get_full_name $cb]/rd_out\[$b\]"]
    if {$p ne ""} { puts "  $tag [get_full_name $p] activity [get_property $p activity]" }
  }
  foreach i $::env(INSTS) {
    report_power -instances [get_cells $i] -digits 6
    foreach pin [get_pins -of_objects [get_cells $i]] {
      puts "  $tag [get_full_name $pin] activity [get_property $pin activity]"
    }
  }
}
if {[info exists ::env(DISABLE)]} {
  set macs [get_cells -filter "ref_name =~ fakeram45_*" *]
  puts "macros [llength $macs] disabled"
  set_disable_timing $macs
}
probe run
