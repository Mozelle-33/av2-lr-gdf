#!/usr/bin/env bash
# ASIC synthesis (ablation recipe, Nangate45, 400 MHz) of the joint stage with
# and without the chroma LR (CH), and a hierarchical run of the chroma unit
# (gdf_lrc kept as a module) for its area.
cd /root/work/asic
syn() {  # dir, chparam string
  local out=/root/work/asic/$1; mkdir -p $out
  sed -e "s/@MAXCH@/1024/" -e "s/@AW@/10/" -e "s/-set FULL @FULL@ -set MSTG @MSTG@/$2/" \
      -e "s/@BOOTH@/-booth/" -e "s/@DELAY@/2500/g" -e "s#@OUT@#$out#g" /mnt/g/AV2/asic/synth_yosys.ys > $out/synth.ys
  nice -n 10 /opt/yosys/bin/yosys -q -l $out/yosys.log -s $out/synth.ys
}
hier() {
  local out=/root/work/asic/hier_joint_ch; mkdir -p $out
  sed -e "s/-set LR 1 gdf_core/-set LR 1 -set CH 1 gdf_core/" -e "s#hier_joint/#hier_joint_ch/#" \
      /mnt/g/AV2/asic/synth_hier_joint.ys > $out/synth.ys
  nice -n 10 /opt/yosys/bin/yosys -q -l $out/yosys.log -s $out/synth.ys
}
syn joint_lr  "-set MSTG 1 -set VS 1 -set PCW 1 -set LR 1" &
syn joint_ch  "-set MSTG 1 -set VS 1 -set PCW 1 -set LR 1 -set CH 1" &
hier &
wait
for d in joint_lr joint_ch; do
  a=$(grep "Chip area for module" $d/stat.txt | tail -1 | awk '{print $NF}')
  ff=$(grep -E "^ +DFF_X1 " $d/stat.txt | tail -1 | awk '{print $2}')
  dl=$(grep -h "Delay =" $d/yosys.log | tail -1 | sed -E 's/.*Delay = *([0-9.]+) ps.*/\1/')
  nu=$(grep -c "is used but has no driver" $d/yosys.log)
  awk -v d=$d -v a=$a -v ff=$ff -v dl=$dl -v nu=$nu 'BEGIN{printf "%-11s %10.0f um2 %7.1f kGE  DFF %6d  delay %s ps  undriven %d\n", d, a, a/0.798/1000, ff, dl, nu}'
done
grep -E "^=== |Chip area for module" hier_joint_ch/stat_hier.txt | grep -B1 "gdf_lrc" | tail -2
echo RUN_JOINT_CH_DONE
