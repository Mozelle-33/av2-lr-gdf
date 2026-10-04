# OOC run of the joint LR/GDF core (VS=1, FIP=1, PCW=1), K7-1 at 4 ns.
# The class ROM file is read relative to the working directory.
$v = 'G:\AMDDesignTools\2026.1.1\Vivado\bin\vivado.bat'
$dir = 'G:\AV2\fpga\ooc'
Copy-Item G:\AV2\rtl\pcw_class.hex $dir -Force
$tag = 'vsfippcw_k1_4ns'
$a = "-mode batch -nojournal -log ooc_$tag.log -source build_ooc.tcl -tclargs xc7k325tffg900-1 4.0 1024 10 $tag 0 1 `"VS=1 PCW=1`""
Start-Process -FilePath $v -ArgumentList $a -WorkingDirectory $dir -WindowStyle Hidden | Out-Null
Start-Sleep 8
Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'vivado.exe' -and $_.CommandLine -match $tag } |
  ForEach-Object { (Get-Process -Id $_.ProcessId).PriorityClass = 'BelowNormal' }
while (Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'vivado.exe' -and $_.CommandLine -match $tag }) { Start-Sleep 20 }
"$tag done: " + ((Select-String -Path "$dir\ooc_$tag.log" -Pattern 'RESULT|Parameter PCW bound|readmem' | ForEach-Object { $_.Line }) -join ' | ')
