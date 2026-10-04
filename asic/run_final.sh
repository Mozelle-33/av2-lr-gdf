#!/usr/bin/env bash
# All ASIC syntheses of the brief from the final RTL (ablation recipe: Booth,
# MSTG=1, abc -D 2500, memories as black boxes), plus the PC-Wiener unit.
cd /root/work/asic
syn() {  # dir, chparam string
  local out=/root/work/asic/fin_$1; mkdir -p $out
  sed -e "s/@MAXCH@/1024/" -e "s/@AW@/10/" -e "s/-set FULL @FULL@ -set MSTG @MSTG@/$2/" \
      -e "s/@BOOTH@/-booth/" -e "s/@DELAY@/2500/g" -e "s#@OUT@#$out#g" /mnt/g/AV2/asic/synth_yosys.ys > $out/synth.ys
  nice -n 10 /opt/yosys/bin/yosys -q -l $out/yosys.log -s $out/synth.ys
}
pool() { while [ $(jobs -r | wc -l) -ge ${JOBS:-4} ]; do sleep 5; done; }
pool; syn v0    "-set MSTG 1 -set MACF 1 -set IDXF 1 -set LA 0" &
pool; syn v1    "-set MSTG 1 -set MACF 0 -set IDXF 1 -set LA 0" &
pool; syn v2    "-set MSTG 1 -set MACF 0 -set IDXF 0 -set LA 0" &
pool; syn v3    "-set MSTG 1 -set MACF 0 -set IDXF 0 -set LA 1" &
pool; syn vs    "-set MSTG 1 -set VS 1" &
pool; syn vsfip "-set MSTG 1 -set VS 1 -set FIP 1" &
pool; syn p4    "-set MSTG 1 -set VS 1 -set GC 2" &
pool; syn p16   "-set MSTG 1 -set VS 1 -set NB 2" &
pool; syn pcwonly "-set MSTG 1 -set VS 1 -set PCW 1 -set GDFB 0" &
wait
mkdir -p /root/work/asic/pcw_unit && (cd /root/work/asic/pcw_unit && \
  /opt/yosys/bin/yosys -q -l yosys.log -s /mnt/g/AV2/asic/synth_pcw.ys > /dev/null 2>&1)
for d in fin_v0 fin_v1 fin_v2 fin_v3 fin_vs fin_vsfip fin_p4 fin_p16 fin_pcwonly pcw_unit; do
  a=$(grep "Chip area for module" $d/stat.txt | tail -1 | awk '{print $NF}')
  ff=$(grep -E "^ +DFF_X1 " $d/stat.txt | tail -1 | awk '{print $2}')
  dl=$(grep -h "Delay =" $d/yosys.log | tail -1 | sed -E 's/.*Delay = *([0-9.]+) ps.*/\1/')
  nu=$(grep -c "is used but has no driver" $d/yosys.log)
  awk -v d=$d -v a=$a -v ff=$ff -v dl=$dl -v nu=$nu 'BEGIN{printf "%-12s %10.0f um2 %7.1f kGE  DFF %6d  delay %s ps  undriven %d\n", d, a, a/0.798/1000, ff, dl, nu}'
done
echo RUN_FINAL_DONE
