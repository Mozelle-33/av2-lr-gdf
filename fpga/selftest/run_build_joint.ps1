# Bitstream build of the on-board self-test with the joint LR/GDF core
# (VS=1, FIP=1, LR=1, 250 MHz).  Builds only; programming the board is a
# separate step (hw_run.tcl).
$v = 'G:\AMDDesignTools\2026.1.1\Vivado\bin\vivado.bat'
$dir = 'G:\AV2\fpga\selftest'
$tag = 'joint_fipvs_250'
$a = "-mode batch -nojournal -log build_$tag.log -source build.tcl -tclargs G:/AV2/fpga/selftest/rom_joint_fipvs 4.0 $tag 1 1 1"
Start-Process -FilePath $v -ArgumentList $a -WorkingDirectory $dir -WindowStyle Hidden | Out-Null
Start-Sleep 8
Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'vivado.exe' -and $_.CommandLine -match $tag } |
  ForEach-Object { (Get-Process -Id $_.ProcessId).PriorityClass = 'BelowNormal' }
while (Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'vivado.exe' -and $_.CommandLine -match $tag }) { Start-Sleep 30 }
"$tag done: " + ((Select-String -Path "$dir\build_$tag.log" -Pattern 'RESULT|BUILD_DONE|ERROR' | ForEach-Object { $_.Line }) -join ' | ')
