# Power and pin activities of the flip-flops that drive some named nets, to
# compare two power runs.  Environment: OUT, SDC, VCD, SCOPE, [MACRO_DIR], NETS
set plat /root/work/pnr/orfs/flow/platforms/nangate45
read_db $::env(OUT)/route.odb
read_liberty $plat/lib/NangateOpenCellLibrary_typical.lib
if {[info exists ::env(MACRO_DIR)]} {
  foreach f [lsort [glob $::env(MACRO_DIR)/*/*.lib]] { read_liberty $f }
}
read_sdc $::env(SDC)
set_propagated_clock [all_clocks]
read_spef $::env(OUT)/gdf.spef
read_vcd -scope $::env(SCOPE) $::env(VCD)
foreach n $::env(NETS) {
  set net [get_nets -quiet $n]
  if {$net eq ""} { puts "net $n not found"; continue }
  foreach p [get_pins -of_objects $net -filter "direction == output"] {
    set inst [get_cells -of_objects $p]
    set cname [get_full_name $inst]
    puts "== net $n driver $cname ([get_property $inst ref_name])"
    report_power -instances $inst -digits 6
    foreach pin [get_pins -of_objects $inst] {
      puts "   [get_full_name $pin] activity [get_property $pin activity]"
    }
  }
}
