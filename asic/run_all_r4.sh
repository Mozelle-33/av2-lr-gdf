#!/usr/bin/env bash
# All ASIC syntheses of the paper from the current RTL (ablation recipe of
# run_final.sh: Booth, MSTG = 1, abc -D 2500, memories as black boxes): the
# ablation variants, the scaled cores, the joint stage without and with the
# luma and chroma LR, the separate cores and the hierarchical runs.
# The reports of the previous runs are kept in /root/work/asic_before_r4.
# Usage: [JOBS=10] run_all_r4.sh          (log: /root/work/asic/run_all_r4.log)
cd /root/work/asic
B=/root/work/asic_before_r4
if [ ! -d $B ]; then
  mkdir -p $B
  for d in */; do
    d=${d%/}; mkdir -p $B/$d
    cp -p $d/stat*.txt $d/yosys.log $B/$d/ 2>/dev/null
  done
fi
L=/root/work/asic/run_all_r4.log
: > $L
export JOBS=${JOBS:-10}
syn() {  # dir, chparam string
  local out=/root/work/asic/$1; mkdir -p $out
  sed -e "s/@MAXCH@/1024/" -e "s/@AW@/10/" -e "s/-set FULL @FULL@ -set MSTG @MSTG@/$2/" \
      -e "s/@BOOTH@/-booth/" -e "s/@DELAY@/2500/g" -e "s#@OUT@#$out#g" /mnt/g/AV2/asic/synth_yosys.ys > $out/synth.ys
  nice -n 10 /opt/yosys/bin/yosys -q -l $out/yosys.log -s $out/synth.ys > /dev/null 2>&1
  echo "done $1 $(date +%T)" >> $L
}
hier() {  # dir, extra parameters
  local out=/root/work/asic/$1; mkdir -p $out
  sed -e "s/-set LR 1 gdf_core/-set LR 1 $2 gdf_core/" -e "s#hier_joint/#$1/#" \
      /mnt/g/AV2/asic/synth_hier_joint.ys > $out/synth.ys
  nice -n 10 /opt/yosys/bin/yosys -q -l $out/yosys.log -s $out/synth.ys > /dev/null 2>&1
  echo "done $1 $(date +%T)" >> $L
}
pool() { while [ $(jobs -r | wc -l) -ge $JOBS ]; do sleep 5; done; }
pool; syn fin_v0       "-set MSTG 1 -set MACF 1 -set IDXF 1 -set LA 0" &
pool; syn fin_v1       "-set MSTG 1 -set MACF 0 -set IDXF 1 -set LA 0" &
pool; syn fin_v2       "-set MSTG 1 -set MACF 0 -set IDXF 0 -set LA 0" &
pool; syn fin_v3       "-set MSTG 1 -set MACF 0 -set IDXF 0 -set LA 1" &
pool; syn fin_vs       "-set MSTG 1 -set VS 1" &
pool; syn fin_vsfip    "-set MSTG 1 -set VS 1 -set FIP 1" &
pool; syn fin_p4       "-set MSTG 1 -set VS 1 -set GC 2" &
pool; syn fin_p16      "-set MSTG 1 -set VS 1 -set NB 2" &
pool; syn fin_pcwonly  "-set MSTG 1 -set VS 1 -set PCW 1 -set GDFB 0" &
pool; syn fin_vspcw    "-set MSTG 1 -set VS 1 -set PCW 1" &
pool; syn joint_lr     "-set MSTG 1 -set VS 1 -set PCW 1 -set LR 1" &
pool; syn fin_lronly   "-set MSTG 1 -set VS 1 -set PCW 1 -set LR 1 -set GDFB 0" &
pool; syn fin_jointfip "-set MSTG 1 -set VS 1 -set PCW 1 -set LR 1 -set FIP 1" &
pool; syn joint_ch     "-set MSTG 1 -set VS 1 -set PCW 1 -set LR 1 -set CH 1" &
pool; hier hier_joint "" &
pool; hier hier_joint_ch "-set CH 1" &
wait
mkdir -p /root/work/asic/pcw_unit && (cd /root/work/asic/pcw_unit && \
  /opt/yosys/bin/yosys -q -l yosys.log -s /mnt/g/AV2/asic/synth_pcw.ys > /dev/null 2>&1)
for d in fin_v0 fin_v1 fin_v2 fin_v3 fin_vs fin_vsfip fin_p4 fin_p16 fin_pcwonly fin_vspcw \
         joint_lr fin_lronly fin_jointfip joint_ch pcw_unit; do
  a=$(grep "Chip area for module" $d/stat.txt | tail -1 | awk '{print $NF}')
  ff=$(grep -E "^ +DFF_X1 " $d/stat.txt | tail -1 | awk '{print $2}')
  dl=$(grep -h "Delay =" $d/yosys.log | tail -1 | sed -E 's/.*Delay = *([0-9.]+) ps.*/\1/')
  nu=$(grep -c "is used but has no driver" $d/yosys.log)
  awk -v d=$d -v a=$a -v ff=$ff -v dl=$dl -v nu=$nu 'BEGIN{printf "%-13s %10.0f um2 %7.1f kGE  DFF %6d  delay %s ps  undriven %d\n", d, a, a/0.798/1000, ff, dl, nu}'
done | tee -a $L
echo RUN_ALL_R4_DONE | tee -a $L
