# SAIF-based power of an OOC gdf_core implementation:
#  1. post-route functional netlist (Vivado)
#  2. xsim of tb_power.v with the real-content stimulus, SAIF over the
#     measured window
#  3. read_saif + report_power on the routed checkpoint (Vivado)
# Usage: run_power.ps1 <ooc tag, e.g. vsfip_k1_4ns> <stimulus dir>
# Steps whose outputs exist are skipped (delete the work directory to redo).
param([string]$tag = 'vsfip_k1_4ns', [string]$stim = 'G:\AV2\fpga\power\stim_set01')
$bin  = 'G:\AMDDesignTools\2026.1.1\Vivado\bin'
$here = 'G:/AV2/fpga/power'
$ooc  = "G:/AV2/fpga/ooc/out_$tag"
$work = "G:\AV2\fpga\power\work_$tag"
$wf   = "G:/AV2/fpga/power/work_$tag"
New-Item -ItemType Directory -Force $work | Out-Null
Copy-Item "$stim\ops.hex", "$stim\in.hex" $work -Force
Set-Location $work
if (-not (Test-Path "$work\gdf_core_funcsim.v")) {
  & "$bin\vivado.bat" -mode batch -nojournal -log funcsim.log -source "$here/write_funcsim.tcl" -tclargs $ooc $wf | Out-Null
}
if (-not (Test-Path "$work\gdf_core_funcsim.v")) { "funcsim netlist missing"; exit 1 }
if (-not (Test-Path "$work\xsim.dir\tbp")) {
  & "$bin\xvlog.bat" -log xvlog.log gdf_core_funcsim.v "$here/tb_power.v" "G:/AMDDesignTools/2026.1.1/Vivado/data/verilog/src/glbl.v" | Out-Null
  & "$bin\xelab.bat" -log xelab.log -L unisims_ver -L secureip -debug typical -timescale 1ns/1ps -s tbp work.tb_power work.glbl | Out-Null
}
& "$bin\xsim.bat" tbp -log xsim.log -tclbatch "$here/saif.tcl" | Out-Null
Select-String -Path xsim.log -Pattern 'segment|DONE|MARKER|ERROR|Error|rror:' | ForEach-Object { $_.Line }
if (-not (Test-Path "$work\power.saif")) { "SAIF missing"; exit 1 }
& "$bin\vivado.bat" -mode batch -nojournal -log power.log -source "$here/power.tcl" -tclargs $ooc $wf | Out-Null
Select-String -Path power_saif.rpt -Pattern 'Total On-Chip Power|Dynamic \(W\)|Device Static|Confidence Level|Design Nets Matched' | ForEach-Object { $_.Line }
Select-String -Path power_vectorless.rpt -Pattern 'Total On-Chip Power|Dynamic \(W\)' | ForEach-Object { "vectorless: " + $_.Line }
"POWER_FLOW_DONE"
