#!/usr/bin/env bash
# ASIC synthesis of the ablation variants (Booth, MSTG=1, abc -D 2500).
#   V0 conventional      MACF=1 IDXF=1 LA=0
#   V1 + supports/swap   MACF=0 IDXF=1 LA=0
#   V2 + mult-free index MACF=0 IDXF=0 LA=0
#   V3 + look-ahead      MACF=0 IDXF=0 LA=1  (proposed)
cd /root/work/asic
for v in "1 1 0" "0 1 0" "0 0 0" "0 0 1"; do
  set -- $v
  out=/root/work/asic/abl_m$1_i$2_la$3; mkdir -p $out
  sed -e "s/@MAXCH@/1024/" -e "s/@AW@/10/" -e "s/-set FULL @FULL@ -set MSTG @MSTG@/-set MSTG 1 -set MACF $1 -set IDXF $2 -set LA $3/" \
      -e "s/@BOOTH@/-booth/" -e "s/@DELAY@/2500/g" -e "s#@OUT@#$out#g" /mnt/g/AV2/asic/synth_yosys.ys > $out/synth.ys
  nice -n 10 /opt/yosys/bin/yosys -q -l $out/yosys.log -s $out/synth.ys &
done
wait
for d in abl_m*; do
  a=$(grep "Chip area for module" $d/stat.txt | tail -1 | awk '{print $NF}')
  ff=$(grep -E "^ +DFF_X1 " $d/stat.txt | tail -1 | awk '{print $2}')
  dl=$(grep -h "Delay =" $d/yosys.log | tail -1 | sed -E 's/.*Delay = *([0-9.]+) ps.*/\1/')
  awk -v d=$d -v a=$a -v ff=$ff -v dl=$dl 'BEGIN{printf "%-16s %10.0f um2 %7.1f kGE  DFF %6d  delay %s ps\n", d, a, a/0.798/1000, ff, dl}'
done
