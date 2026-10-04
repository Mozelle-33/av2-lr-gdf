# Program the self-test bitstream (volatile, JTAG only) and read the results.
# Usage: vivado -mode batch -source hw_run.tcl -tclargs <bitfile> [reads=10] [interval_s=30] [inject=1] [restore=0]
#   USER1 (IR 0x02): 264-bit status {6'b0, run, locked, snapshot[255:0]}
#   USER2 (IR 0x03): 32-bit control {16'hC0DE, 14'b0, inject, soft_reset}
#   restore=1: clear the configuration at the end (JPROGRAM); the flash is
#   erased, so the FPGA returns to its unconfigured power-on state.
# Safety: if the die temperature exceeds 80 C the test is held in reset and
# the run stops.
lassign $argv bit nreads interval inject restore
if {$nreads eq ""} { set nreads 10 }
if {$interval eq ""} { set interval 30 }
if {$inject eq ""} { set inject 1 }
if {$restore eq ""} { set restore 0 }
set tmax 80.0

proc sysmon {dev} {
  set sm [lindex [get_hw_sysmons -quiet -of_objects $dev] 0]
  if {$sm eq ""} { return "no sysmon" }
  refresh_hw_sysmon $sm
  return "temp=[get_property TEMPERATURE $sm]C vccint=[get_property VCCINT $sm] vccaux=[get_property VCCAUX $sm] vccbram=[get_property VCCBRAM $sm]"
}

# hex string -> list of 32-bit words, word 0 = bits [31:0]
proc words {hex nbits} {
  set hex [string trimleft [string tolower $hex] "0x"]
  set n [expr {($nbits + 3) / 4}]
  set hex [format "%0${n}s" $hex]
  set hex [string map {" " 0} $hex]
  set w {}
  for {set i 0} {$i < ($nbits + 31) / 32} {incr i} {
    set e [expr {$n - 8 * $i}]
    set s [expr {max(0, $e - 8)}]
    lappend w [expr "0x[string range $hex $s [expr {$e - 1}]]"]
  }
  return $w
}

# USER1 data register: status and snapshot of the self-test
proc read_user1 {} {
  scan_ir_hw_jtag 6 -tdi 02
  set r [scan_dr_hw_jtag 264 -tdi 0]
  return $r
}

# fields of the snapshot (rtl/gdf_selftest.v), as a text line
proc decode {r} {
  set w [words $r 264]
  set stat [expr {[lindex $w 8] & 0xFF}]
  set w7 [lindex $w 7]
  return [format "status %02x magic %04x ver %02x flags %02x loops %u seg_ok %u seg_bad %u groups %u run_cycles %u loop_cycles %u bad_total %u" \
    $stat [expr {$w7 >> 16}] [expr {($w7 >> 8) & 0xFF}] [expr {$w7 & 0xFF}] \
    [lindex $w 6] [lindex $w 5] [lindex $w 4] [lindex $w 3] [lindex $w 2] [lindex $w 1] [lindex $w 0]]
}

# USER2 data register: control word (inject, soft reset)
proc write_user2 {val} {
  scan_ir_hw_jtag 6 -tdi 03
  scan_dr_hw_jtag 32 -tdi [format %08x $val]
}

# program the device (volatile) and check DONE and the supplies
open_hw_manager
connect_hw_server
open_hw_target
set devs [get_hw_devices]
puts "DEVICES $devs"
if {[llength $devs] != 1} { puts "ERROR: expected exactly one device in the chain"; exit 1 }
set dev [lindex $devs 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
puts "BEFORE [sysmon $dev]"
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
refresh_hw_device -update_hw_probes false $dev
puts "DONE_PIN [get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev]"
puts "AFTER_PROGRAM [sysmon $dev]"
close_hw_target

# status reads: two consecutive reads each, with the die temperature
set t0 [clock milliseconds]
for {set i 0} {$i < $nreads} {incr i} {
  after [expr {$i == 0 ? 3000 : $interval * 1000}]
  open_hw_target -jtag_mode on
  run_state_hw_jtag RESET
  run_state_hw_jtag IDLE
  set a [read_user1]
  set b [read_user1]
  close_hw_target
  open_hw_target
  current_hw_device [lindex [get_hw_devices] 0]
  set sm [sysmon [lindex [get_hw_devices] 0]]
  close_hw_target
  set t [expr {([clock milliseconds] - $t0) / 1000.0}]
  puts [format "READ %d t=%.1fs raw=%s" $i $t $a]
  puts [format "DEC  %d t=%.1fs %s | %s" $i $t [decode $a] $sm]
  if {$a ne $b} { puts "NOTE second read differs (snapshot updated between reads): [decode $b]" }
  if {[regexp {temp=([0-9.]+)} $sm -> tc] && $tc > $tmax} {
    puts "ALARM temperature $tc C > $tmax C: holding the test in reset"
    open_hw_target -jtag_mode on
    run_state_hw_jtag RESET
    run_state_hw_jtag IDLE
    write_user2 0xC0DE0001
    close_hw_target
    set inject 0
    break
  }
}

# error injection for two seconds: every loop must then report a bad segment
if {$inject} {
  open_hw_target -jtag_mode on
  run_state_hw_jtag RESET
  run_state_hw_jtag IDLE
  write_user2 0xC0DE0002
  after 2000
  puts "INJECT_ON  [decode [read_user1]]"
  write_user2 0xC0DE0000
  after 2000
  puts "INJECT_OFF [decode [read_user1]]"
  close_hw_target
}
if {$restore} {
  open_hw_target
  set dev [lindex [get_hw_devices] 0]
  current_hw_device $dev
  # JPROGRAM clears the configuration; the boot from the erased flash then
  # fails (expected), leaving the device unconfigured as after power-up
  catch {boot_hw_device $dev}
  refresh_hw_device -update_hw_probes false $dev
  puts "RESTORED done=[get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev]"
  close_hw_target
}
disconnect_hw_server
puts "RUN_DONE"
