# Queue the FIP OOC run (K7-1, 4 ns) after all running build_ooc jobs,
# at below-normal priority.
$v = 'G:\AMDDesignTools\2026.1.1\Vivado\bin\vivado.bat'
$dir = 'G:\AV2\fpga\ooc'
function Busy { [bool](Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'vivado.exe' -and $_.CommandLine -match 'build_ooc.tcl' }) }
# wait for the ablation queue (three runs) to drain
Start-Sleep 30
while ((Busy) -or -not (Test-Path "$dir\out_abl_v2_k1\worst_endpoints.txt")) { Start-Sleep 30 }
$a = '-mode batch -nojournal -log ooc_fip2_k1.log -source build_ooc.tcl -tclargs xc7k325tffg900-1 4.0 1024 10 fip2_k1_4ns 0 1'
Start-Process -FilePath $v -ArgumentList $a -WorkingDirectory $dir -WindowStyle Hidden | Out-Null
Start-Sleep 8
Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'vivado.exe' -and $_.CommandLine -match 'fip2_k1' } |
  ForEach-Object { (Get-Process -Id $_.ProcessId).PriorityClass = 'BelowNormal' }
while (Busy) { Start-Sleep 30 }
"fip2 done"
