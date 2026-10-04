# SAIF-based power of an OOC joint LR/GDF core (fpga/ooc/out_<tag>):
#  1. post-route functional netlist (Vivado)
#  2. xsim of tb_power_joint.v replaying the RTL port trace in the work
#     directory (ports.hex, outs.hex [, cports.hex, couts.hex], trace.vh from
#     scripts/power_trace_fpga.sh), SAIF over the window of the ASIC power
#     estimate; every valid output is checked
#  3. read_saif + report_power on the routed checkpoint (Vivado)
# Steps whose outputs exist are skipped (delete files in the work directory to redo).
# Usage: run_power_joint.ps1 -tag jointfip_final_k1_4ns -work work_jointfip_final
#        run_power_joint.ps1 -tag jointfipch_k1_4ns -work work_jointfipch -chroma
param([string]$tag = 'jointfip_final_k1_4ns', [string]$work = 'work_jointfip_final', [switch]$chroma)
$bin  = 'G:\AMDDesignTools\2026.1.1\Vivado\bin'
$here = 'G:/AV2/fpga/power'
$ooc  = "G:/AV2/fpga/ooc/out_$tag"
$wd   = "G:\AV2\fpga\power\$work"
$wf   = "G:/AV2/fpga/power/$work"
Set-Location $wd
if (-not (Test-Path "$wd\gdf_core_funcsim.v")) {
  & "$bin\vivado.bat" -mode batch -nojournal -log funcsim.log -source "$here/write_funcsim.tcl" -tclargs $ooc $wf | Out-Null
}
if (-not (Test-Path "$wd\gdf_core_funcsim.v")) { "funcsim netlist missing"; exit 1 }
if (-not (Test-Path "$wd\xsim.dir\tbpj")) {
  $def = @()
  if ($chroma) { $def = @('-d', 'CHROMA') }
  & "$bin\xvlog.bat" -log xvlog.log -i . @def gdf_core_funcsim.v "$here/tb_power_joint.v" "G:/AMDDesignTools/2026.1.1/Vivado/data/verilog/src/glbl.v" | Out-Null
  & "$bin\xelab.bat" -log xelab.log -L unisims_ver -L secureip -debug typical -timescale 1ns/1ps `
    -s tbpj work.tb_power_joint work.glbl | Out-Null
}
if (-not (Test-Path "$wd\power.saif")) {
  & "$bin\xsim.bat" tbpj -log xsim.log -tclbatch "$here/saif_joint.tcl" | Out-Null
}
Select-String -Path xsim.log -Pattern 'MARKER|DONE|MISMATCH|ERROR|rror:' | ForEach-Object { $_.Line }
if (-not (Test-Path "$wd\power.saif")) { "SAIF missing"; exit 1 }
& "$bin\vivado.bat" -mode batch -nojournal -log power.log -source "$here/power_joint.tcl" -tclargs $ooc $wf | Out-Null
Select-String -Path power_saif.rpt -Pattern 'Total On-Chip Power|Dynamic \(W\)|Device Static|Confidence Level|Design Nets Matched' | ForEach-Object { $_.Line }
Select-String -Path power_vectorless.rpt -Pattern 'Total On-Chip Power|Dynamic \(W\)' | ForEach-Object { "vectorless: " + $_.Line }
"POWER_FLOW_DONE"
