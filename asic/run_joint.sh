#!/usr/bin/env bash
# ASIC synthesis (ablation recipe) of the joint LR/GDF front end:
#   gdf  : column-major GDF core (PCW=0)
#   joint: GDF core + PC-Wiener classifier on the shared front end (PCW=1)
#   pcw  : PC-Wiener classifier with its own front end, no GDF back end
cd /root/work/asic
syn() {  # dir, chparam string
  local out=/root/work/asic/$1; mkdir -p $out
  sed -e "s/@MAXCH@/1024/" -e "s/@AW@/10/" -e "s/-set FULL @FULL@ -set MSTG @MSTG@/$2/" \
      -e "s/@BOOTH@/-booth/" -e "s/@DELAY@/2500/g" -e "s#@OUT@#$out#g" /mnt/g/AV2/asic/synth_yosys.ys > $out/synth.ys
  nice -n 10 /opt/yosys/bin/yosys -q -l $out/yosys.log -s $out/synth.ys
}
syn joint_gdf   "-set MSTG 1 -set VS 1 -set PCW 0" &
syn joint_both  "-set MSTG 1 -set VS 1 -set PCW 1" &
syn joint_pcw   "-set MSTG 1 -set VS 1 -set PCW 1 -set GDFB 0" &
wait
for d in joint_gdf joint_both joint_pcw; do
  a=$(grep "Chip area for module" $d/stat.txt | tail -1 | awk '{print $NF}')
  ff=$(grep -E "^ +DFF_X1 " $d/stat.txt | tail -1 | awk '{print $2}')
  dl=$(grep -h "Delay =" $d/yosys.log | tail -1 | sed -E 's/.*Delay = *([0-9.]+) ps.*/\1/')
  nu=$(grep -c "is used but has no driver" $d/yosys.log)
  awk -v d=$d -v a=$a -v ff=$ff -v dl=$dl -v nu=$nu 'BEGIN{printf "%-11s %10.0f um2 %7.1f kGE  DFF %6d  delay %s ps  undriven %d\n", d, a, a/0.798/1000, ff, dl, nu}'
done
echo RUN_JOINT_DONE
