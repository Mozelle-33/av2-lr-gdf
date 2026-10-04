# Sequential Vivado jobs for the column-major core (VS=1), below-normal
# priority: OOC K7-1 at 4 ns with FIP=0 and FIP=1, then the 250 MHz self-test
# bitstream (VS=1, FIP=1).  The generics string must be quoted: vivado.bat
# splits unquoted arguments at '='.
$v = 'G:\AMDDesignTools\2026.1.1\Vivado\bin\vivado.bat'
$jobs = @(
  @{ tag = 'vs_k1_4ns';    dir = 'G:\AV2\fpga\ooc';
     a = "-mode batch -nojournal -log ooc_vs_k1_4ns.log -source build_ooc.tcl -tclargs xc7k325tffg900-1 4.0 1024 10 vs_k1_4ns 0 0 `"VS=1`"" },
  @{ tag = 'vsfip_k1_4ns'; dir = 'G:\AV2\fpga\ooc';
     a = "-mode batch -nojournal -log ooc_vsfip_k1_4ns.log -source build_ooc.tcl -tclargs xc7k325tffg900-1 4.0 1024 10 vsfip_k1_4ns 0 1 `"VS=1`"" },
  @{ tag = 'fipvs_250';    dir = 'G:\AV2\fpga\selftest';
     a = "-mode batch -nojournal -log build_fipvs_250.log -source build.tcl -tclargs G:/AV2/fpga/selftest/rom_v2_fipvs 4.0 fipvs_250 1 1" }
)
foreach ($j in $jobs) {
  $p = Start-Process -FilePath $v -ArgumentList $j.a -WorkingDirectory $j.dir -WindowStyle Hidden -PassThru
  Start-Sleep 8
  Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'vivado.exe' -and $_.CommandLine -match $j.tag } |
    ForEach-Object { (Get-Process -Id $_.ProcessId).PriorityClass = 'BelowNormal' }
  while (Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'vivado.exe' -and $_.CommandLine -match $j.tag }) { Start-Sleep 20 }
  $log = Get-ChildItem $j.dir -Filter "*$($j.tag).log" | Select-Object -First 1
  "$($j.tag) done: " + ((Select-String -Path $log.FullName -Pattern 'RESULT|BUILD_DONE|ERROR' | Select-Object -Last 3 | ForEach-Object { $_.Line }) -join ' | ')
}
