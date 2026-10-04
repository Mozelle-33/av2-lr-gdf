# Out-of-context reruns of every FPGA configuration of the paper on the final
# RTL (XC7K325T-1, 4 ns, 4096-column segments): the joint stage with and
# without the chroma LR, and the six rows of the ablation.  Two Vivado jobs at a
# time, at below-normal priority; the earlier results stay in their own
# directories (tags without _r4).  Software only: no board access.
# Usage: powershell -File run_r4_ooc.ps1        (log: run_r4_ooc.log)
$v   = 'G:\AMDDesignTools\2026.1.1\Vivado\bin\vivado.bat'
$dir = 'G:\AV2\fpga\ooc'
$log = "$dir\run_r4_ooc.log"
$max = 2
$runs = @(
  @{tag='jointfipch_r4'; full='0'; fip='1'; extra='VS=1 PCW=1 LR=1 CH=1'},
  @{tag='jointfip_r4';   full='0'; fip='1'; extra='VS=1 PCW=1 LR=1'},
  @{tag='vsfip_r4';      full='0'; fip='1'; extra='VS=1'},
  @{tag='vs_r4';         full='0'; fip='0'; extra='VS=1'},
  @{tag='v3_r4';         full='0'; fip='0'; extra='MACF=0 IDXF=0 LA=1'},
  @{tag='abl_v2_r4';     full='0'; fip='0'; extra='MACF=0 IDXF=0 LA=0'},
  @{tag='abl_v1_r4';     full='0'; fip='0'; extra='MACF=0 IDXF=1 LA=0'},
  @{tag='abl_v0_r4';     full='1'; fip='0'; extra='MACF=1 IDXF=1 LA=0'}
)
function Mine { @(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'vivado.exe' -and $_.CommandLine -match 'build_ooc.tcl' -and $_.CommandLine -match '_r4 ' }) }
"queue start $(Get-Date -Format s)" | Out-File $log
foreach ($r in $runs) {
  while ((Mine).Count -ge $max) { Start-Sleep 20 }
  $a = "-mode batch -nojournal -log ooc_$($r.tag).log -source build_ooc.tcl -tclargs xc7k325tffg900-1 4.0 1024 10 $($r.tag) $($r.full) $($r.fip) `"$($r.extra)`""
  Start-Process -FilePath $v -ArgumentList $a -WorkingDirectory $dir -WindowStyle Hidden | Out-Null
  Start-Sleep 15
  Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'vivado.exe' -and $_.CommandLine -match "$($r.tag) " } |
    ForEach-Object { (Get-Process -Id $_.ProcessId).PriorityClass = 'BelowNormal' }
  "started $($r.tag) $(Get-Date -Format s)" | Out-File $log -Append
}
while ((Mine).Count -gt 0) { Start-Sleep 20 }
foreach ($r in $runs) {
  "$($r.tag): " + ((Select-String -Path "$dir\ooc_$($r.tag).log" -Pattern 'RESULT|REPORTS_DONE|^ERROR' | Select-Object -Last 2 | ForEach-Object { $_.Line }) -join ' | ') | Out-File $log -Append
}
"R4_OOC_DONE $(Get-Date -Format s)" | Out-File $log -Append
