#!/usr/bin/env bash
# ASIC synthesis of the column-major core (VS=1) next to the row-major V3,
# both from the current RTL (Booth, MSTG=1, abc -D 2500), plus VS with FIP.
cd /root/work/asic
syn() {  # dir, chparam string
  local out=/root/work/asic/$1; mkdir -p $out
  sed -e "s/@MAXCH@/1024/" -e "s/@AW@/10/" -e "s/-set FULL @FULL@ -set MSTG @MSTG@/$2/" \
      -e "s/@BOOTH@/-booth/" -e "s/@DELAY@/2500/g" -e "s#@OUT@#$out#g" /mnt/g/AV2/asic/synth_yosys.ys > $out/synth.ys
  nice -n 10 /opt/yosys/bin/yosys -q -l $out/yosys.log -s $out/synth.ys
}
syn abl_m0_i0_la1_r2   "-set MSTG 1 -set MACF 0 -set IDXF 0 -set LA 1 -set VS 0" &
syn abl_m0_i0_la1_vs   "-set MSTG 1 -set MACF 0 -set IDXF 0 -set LA 1 -set VS 1" &
syn abl_m0_i0_la1_vsf  "-set MSTG 1 -set MACF 0 -set IDXF 0 -set LA 1 -set VS 1 -set FIP 1" &
wait
bash /mnt/g/AV2/asic/abl_summary.sh
echo RUN_VS_DONE
