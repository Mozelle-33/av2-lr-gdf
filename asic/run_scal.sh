#!/usr/bin/env bash
# ASIC synthesis (same recipe as the ablation: Booth, MSTG=1, abc -D 2500,
# SRAMs as black boxes) of the column-major core at 4, 8 and 16 samples/cycle.
cd /root/work/asic
syn() {  # dir, chparam string
  local out=/root/work/asic/$1; mkdir -p $out
  sed -e "s/@MAXCH@/1024/" -e "s/@AW@/10/" -e "s/-set FULL @FULL@ -set MSTG @MSTG@/$2/" \
      -e "s/@BOOTH@/-booth/" -e "s/@DELAY@/2500/g" -e "s#@OUT@#$out#g" /mnt/g/AV2/asic/synth_yosys.ys > $out/synth.ys
  nice -n 10 /opt/yosys/bin/yosys -q -l $out/yosys.log -s $out/synth.ys
}
syn scal_p4  "-set MSTG 1 -set VS 1 -set NB 1 -set GC 2" &
syn scal_p8  "-set MSTG 1 -set VS 1 -set NB 1 -set GC 4" &
syn scal_p16 "-set MSTG 1 -set VS 1 -set NB 2 -set GC 4" &
wait
for d in scal_p4 scal_p8 scal_p16; do
  a=$(grep "Chip area for module" $d/stat.txt | tail -1 | awk '{print $NF}')
  ff=$(grep -E "^ +DFF_X1 " $d/stat.txt | tail -1 | awk '{print $2}')
  dl=$(grep -h "Delay =" $d/yosys.log | tail -1 | sed -E 's/.*Delay = *([0-9.]+) ps.*/\1/')
  nu=$(grep -c "is used but has no driver" $d/yosys.log)
  awk -v d=$d -v a=$a -v ff=$ff -v dl=$dl -v nu=$nu 'BEGIN{printf "%-10s %10.0f um2 %7.1f kGE  DFF %6d  delay %s ps  undriven %d\n", d, a, a/0.798/1000, ff, dl, nu}'
done
echo RUN_SCAL_DONE
