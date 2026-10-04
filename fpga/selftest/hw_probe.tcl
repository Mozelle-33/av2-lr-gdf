# Read-only JTAG probe: lists targets, devices, IDCODEs and SYSMON readings.
# Usage: vivado -mode batch -source hw_probe.tcl
open_hw_manager
connect_hw_server
foreach t [get_hw_targets] {
  puts "TARGET $t"
}
open_hw_target
foreach d [get_hw_devices] {
  puts "DEVICE $d part=[get_property PART $d] idcode=[get_property IDCODE_HEX $d] ir=[get_property IR_LENGTH $d] done=[get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $d]"
}
set dev [lindex [get_hw_devices xc7k325t*] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
foreach sm [get_hw_sysmons -quiet] {
  puts "SYSMON temp=[get_property TEMPERATURE $sm] vccint=[get_property VCCINT $sm] vccaux=[get_property VCCAUX $sm] vccbram=[get_property VCCBRAM $sm]"
}
close_hw_target
disconnect_hw_server
puts "PROBE_DONE"
