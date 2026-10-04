#!/usr/bin/env bash
# ASIC syntheses of the joint LR/GDF core (final recipe of run_final.sh:
# Booth, MSTG=1, abc -D 2500, memories and ROMs as black boxes).
cd /root/work/asic
syn() {  # dir, chparam string
  local out=/root/work/asic/fin_$1; mkdir -p $out
  sed -e "s/@MAXCH@/1024/" -e "s/@AW@/10/" -e "s/-set FULL @FULL@ -set MSTG @MSTG@/$2/" \
      -e "s/@BOOTH@/-booth/" -e "s/@DELAY@/2500/g" -e "s#@OUT@#$out#g" /mnt/g/AV2/asic/synth_yosys.ys > $out/synth.ys
  nice -n 10 /opt/yosys/bin/yosys -q -l $out/yosys.log -s $out/synth.ys
}
pool() { while [ $(jobs -r | wc -l) -ge ${JOBS:-4} ]; do sleep 5; done; }
pool; syn joint   "-set MSTG 1 -set VS 1 -set PCW 1 -set LR 1" &
pool; syn lronly  "-set MSTG 1 -set VS 1 -set PCW 1 -set LR 1 -set GDFB 0" &
# vspcw unchanged by the LR back end
pool; syn jointfip "-set MSTG 1 -set VS 1 -set PCW 1 -set LR 1 -set FIP 1" &
wait
for d in fin_vs fin_vspcw fin_joint fin_jointfip fin_lronly fin_pcwonly; do
  a=$(grep "Chip area for module" $d/stat.txt | tail -1 | awk '{print $NF}')
  ff=$(grep -E "^ +DFF_X1 " $d/stat.txt | tail -1 | awk '{print $2}')
  dl=$(grep -h "Delay =" $d/yosys.log | tail -1 | sed -E 's/.*Delay = *([0-9.]+) ps.*/\1/')
  nu=$(grep -c "is used but has no driver" $d/yosys.log)
  awk -v d=$d -v a=$a -v ff=$ff -v dl=$dl -v nu=$nu 'BEGIN{printf "%-12s %10.0f um2 %7.1f kGE  DFF %6d  delay %s ps  undriven %d\n", d, a, a/0.798/1000, ff, dl, nu}'
done
echo RUN_LR_DONE
