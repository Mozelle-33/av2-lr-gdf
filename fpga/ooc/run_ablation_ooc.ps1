# Sequential, below-normal-priority OOC runs of the ablation variants
# (XC7K325T-1, 4 ns, 4096-column segments).  Waits for any running
# ooc_* Vivado job of this project to finish first.
$v = 'G:\AMDDesignTools\2026.1.1\Vivado\bin\vivado.bat'
$dir = 'G:\AV2\fpga\ooc'
$runs = @(
  @{tag='abl_v0_k1'; full='1'; extra='MACF=1 IDXF=1 LA=0'},
  @{tag='abl_v1_k1'; full='0'; extra='MACF=0 IDXF=1 LA=0'},
  @{tag='abl_v2_k1'; full='0'; extra='MACF=0 IDXF=0 LA=0'}
)
function Wait-Ooc {
  while (Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'vivado.exe' -and $_.CommandLine -match 'build_ooc.tcl' }) {
    Start-Sleep 20
  }
}
foreach ($r in $runs) {
  Wait-Ooc
  $args = "-mode batch -nojournal -log ooc_$($r.tag).log -source build_ooc.tcl -tclargs xc7k325tffg900-1 4.0 1024 10 $($r.tag) $($r.full) 0 `"$($r.extra)`""
  $p = Start-Process -FilePath $v -ArgumentList $args -WorkingDirectory $dir -WindowStyle Hidden -PassThru
  Start-Sleep 8
  Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'vivado.exe' -and $_.CommandLine -match $r.tag } |
    ForEach-Object { (Get-Process -Id $_.ProcessId).PriorityClass = 'BelowNormal' }
  "started $($r.tag)"
}
Wait-Ooc
"all ablation OOC runs done"
