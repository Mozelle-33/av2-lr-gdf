#!/usr/bin/env bash
# ASIC synthesis of the proposed core with the fast inner product (FIP=1).
cd /root/work/asic
out=/root/work/asic/abl_m0_i0_la1_fip; mkdir -p $out
sed -e "s/@MAXCH@/1024/" -e "s/@AW@/10/" -e "s/-set FULL @FULL@ -set MSTG @MSTG@/-set MSTG 1 -set FIP 1/" \
    -e "s/@BOOTH@/-booth/" -e "s/@DELAY@/2500/g" -e "s#@OUT@#$out#g" /mnt/g/AV2/asic/synth_yosys.ys > $out/synth.ys
nice -n 10 /opt/yosys/bin/yosys -q -l $out/yosys.log -s $out/synth.ys
bash /mnt/g/AV2/asic/abl_summary.sh
