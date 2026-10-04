# SAIF-annotated power of an OOC gdf_core run.
# Usage: vivado -mode batch -source power.tcl -tclargs <ooc_out_dir> <workdir>
lassign $argv ooc work
open_checkpoint $ooc/routed.dcp
report_power -file $work/power_vectorless.rpt
read_saif -file $work/power.saif -strip_path tb_power/dut -out_file $work/read_saif.log
report_power -file $work/power_saif.rpt
report_power -hierarchical_depth 1 -file $work/power_saif_hier.rpt
puts "POWER_DONE"
