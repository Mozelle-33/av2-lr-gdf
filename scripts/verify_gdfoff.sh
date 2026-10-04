#!/usr/bin/env bash
# GDF side stream in_gdf (block flag / local mode of AV2): full-width stripes
# of every LR-enabled stream that has units with GDF off (scripts/
# decode_gdfoff.sh), with the reference decoder's on/off pattern, and with 30 %
# of the groups switched off at random (the on/off boundaries then fall on
# arbitrary groups); ASIC pipeline (MSTG = 1) and FPGA pipeline with the fast
# inner product (MSTG = 2, FIP = 1).  The negative run (GDF_IGNORE_OFF = 1:
# the side bit kept at 1) must fail.  Log: /root/work/verify_gdfoff.log
set -uo pipefail
R=/mnt/g/AV2
V=/root/work/vec_off
L=/root/work/verify_gdfoff.log
mkdir -p $V
: > $L
sum() {  # sum the summary lines of tb_gdf over several runs
  grep '^segments' | awk -F', ' '{ for (i = 1; i <= NF; i++) { k = $i; sub(/ [0-9]+$/, "", k);
    v = $i; sub(/.* /, "", v); if (!(k in s)) o[++m] = k; s[k] += v } }
    END { for (j = 1; j <= m; j++) printf "%s%s %d", (j > 1 ? ", " : ""), o[j], s[o[j]]; print "" }'
}
python3 $R/tools/make_pcw_rom.py >/dev/null
for m in "1 0" "2 1"; do
  set -- $m
  fip=(); [ $2 = 1 ] && fip=(--fip)
  for kind in real stress neg; do
    for o in /root/work/dumps_lr/*.gdfoff /root/work/dumps_4k/*.gdfoff; do
      [ -s "$o" ] || continue
      g=${o%.gdfoff}.gdfdump; l=${o%.gdfoff}.lrdump
      [ -f "$g" ] && [ -f "$l" ] || continue
      n=$(basename "$o" .gdfoff)
      st=(); [ $kind = stress ] && st=(--offstress 30)
      if [ $kind != neg ]; then
        python3 $R/tools/make_wide_vectors.py $V/${kind}_$n.vec "$g" "$l" --off "$o" "${st[@]}" "${fip[@]}" | sed "s/^/$kind m$1 fip$2 /" >> $L
        MAXCH=1024 AW=10 VS=1 PCW=1 LR=1 MSTG=$1 FIP=$2 bash $R/scripts/sim.sh $V/${kind}_$n.vec 2>&1 | tail -1
      else
        GDF_IGNORE_OFF=1 MAXCH=1024 AW=10 VS=1 PCW=1 LR=1 MSTG=$1 FIP=$2 bash $R/scripts/sim.sh $V/real_$n.vec 2>&1 | tail -1
      fi
    done | sum | sed "s/^/$kind m$1 fip$2: /" | tee -a $L
  done
done
ok=1
[ "$(grep -c '^real .*mismatches 0,' $L)" = 2 ] || ok=0
[ "$(grep -c '^stress .*mismatches 0,' $L)" = 2 ] || ok=0
[ "$(grep -c '^neg .*mismatches 0,' $L)" = 0 ] || ok=0
[ $ok = 1 ] && echo VERIFY_GDFOFF_PASS | tee -a $L || echo VERIFY_GDFOFF_FAIL | tee -a $L
