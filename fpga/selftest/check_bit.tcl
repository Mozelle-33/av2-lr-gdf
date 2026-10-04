# Safety check of a routed self-test checkpoint before programming the board.
# Usage: vivado -mode batch -source check_bit.tcl -tclargs <routed.dcp>
open_checkpoint [lindex $argv 0]
foreach p {BITSTREAM.CONFIG.UNUSEDPIN CFGBVS CONFIG_VOLTAGE BITSTREAM.GENERAL.COMPRESS} {
  puts "PROP $p = [get_property $p [current_design]]"
}
foreach port [get_ports] {
  puts "PORT $port dir=[get_property DIRECTION $port] pin=[get_property PACKAGE_PIN $port] iostd=[get_property IOSTANDARD $port]"
}
puts "NPORTS [llength [get_ports]]"
