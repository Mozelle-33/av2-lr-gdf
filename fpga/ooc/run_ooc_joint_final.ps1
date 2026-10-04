# Out-of-context implementation of the luma joint stage (VS = 1, PCW = 1, LR = 1,
# FPGA pipeline with the fast inner product) on the final RTL, for resources and
# timing at 250 MHz (the run of 2026-09-27 is kept in out_jointfip_k1_4ns).
# Software only: no board access.  Vivado runs at below-normal priority.
# Usage: powershell -File run_ooc_joint_final.ps1
$v = 'G:\AMDDesignTools\2026.1.1\Vivado\bin\vivado.bat'
$dir = 'G:\AV2\fpga\ooc'
$tag = 'jointfip_final_k1_4ns'
$a = "-mode batch -nojournal -log ooc_$tag.log -source build_ooc.tcl -tclargs xc7k325tffg900-1 4.0 1024 10 $tag 0 1 `"VS=1 PCW=1 LR=1`""
Start-Process -FilePath $v -ArgumentList $a -WorkingDirectory $dir -WindowStyle Hidden | Out-Null
Start-Sleep 8
Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'vivado.exe' -and $_.CommandLine -match $tag } |
  ForEach-Object { (Get-Process -Id $_.ProcessId).PriorityClass = 'BelowNormal' }
while (Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'vivado.exe' -and $_.CommandLine -match $tag }) { Start-Sleep 20 }
"$tag done: " + ((Select-String -Path "$dir\ooc_$tag.log" -Pattern 'RESULT' | ForEach-Object { $_.Line }) -join ' | ')
