# Post-route functional netlist of an OOC gdf_core run for the SAIF simulation.
# Usage: vivado -mode batch -source write_funcsim.tcl -tclargs <ooc_out_dir> <workdir>
lassign $argv ooc work
open_checkpoint $ooc/routed.dcp
write_verilog -mode funcsim -force $work/gdf_core_funcsim.v
puts "FUNCSIM_DONE"
