# Out-of-context implementation of the joint stage with the chroma LR (FPGA
# pipeline MSTG = 2 with the fast inner product, as out_jointfip_k1_4ns) for
# resources and timing at 250 MHz.  Software only: no board access.
# Starts Vivado at below-normal priority (children inherit it) and waits.
# Usage: powershell -File run_ooc_ch.ps1
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here
$viv = "G:\AMDDesignTools\2026.1.1\Vivado\bin\vivado.bat"
$tag = "jointfipch_k1_4ns"
# the generics string must stay one argument (vivado.bat splits at '=')
$cmd = "start `"`" /belownormal /wait /b `"$viv`" -mode batch -nojournal -log ooc_$tag.log " +
       "-source build_ooc.tcl -tclargs xc7k325tffg900-1 4.0 1024 10 $tag 0 1 `"VS=1 PCW=1 LR=1 CH=1`""
cmd /c $cmd
Select-String -Path "ooc_$tag.log" -Pattern "RESULT tag|REPORTS_DONE" | ForEach-Object { $_.Line }
