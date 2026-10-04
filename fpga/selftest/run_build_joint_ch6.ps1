# Bitstream build of the on-board self-test with the final joint stage and the
# chroma LR (VS=1, FIP=1, LR=1, CH=1, 250 MHz, GDF side stream) and the ROMs of
# scripts/rom_joint_ch6.sh (a full-width 4K stripe with chroma and bank
# reloads, a full-width 720p stripe with GDF on/off blocks and chroma, joint
# units with chroma, chroma stripe segments with the down-sampling filters 0
# and 2 and 10-bit samples, luma LR stress units).
# Builds only; programming the board is a separate step (hw_run.tcl).
$v = 'G:\AMDDesignTools\2026.1.1\Vivado\bin\vivado.bat'
$dir = 'G:\AV2\fpga\selftest'
$tag = 'joint_ch6_fipvs_250'
$a = "-mode batch -nojournal -log build_$tag.log -source build.tcl -tclargs G:/AV2/fpga/selftest/rom_joint_ch6_fipvs 4.0 $tag 1 1 1 1 explore"
Start-Process -FilePath $v -ArgumentList $a -WorkingDirectory $dir -WindowStyle Hidden | Out-Null
Start-Sleep 8
Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'vivado.exe' -and $_.CommandLine -match $tag } |
  ForEach-Object { (Get-Process -Id $_.ProcessId).PriorityClass = 'BelowNormal' }
while (Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'vivado.exe' -and $_.CommandLine -match $tag }) { Start-Sleep 30 }
"$tag done: " + ((Select-String -Path "$dir\build_$tag.log" -Pattern 'RESULT|BUILD_DONE|ERROR' | ForEach-Object { $_.Line }) -join ' | ')
