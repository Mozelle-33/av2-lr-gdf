#!/usr/bin/env bash
# 4K verification (Crosswalk 3840x2160, 10 bit, LR on; scripts/encode_batch_4k.sh):
# decoder profile and dumps, bit-exact Python models, the RTL on the GDF units,
# LR units, multi-unit LR segments and joint units as in verify_final.sh, and
# full-width joint segments (3840 columns, and split at column 1920) with the
# coefficient banks reloaded during the segment.  Log: /root/work/verify_4k.log
set -uo pipefail
R=/mnt/g/AV2
B=/root/work/bit_4k
D=/root/work/dumps_4k
V=/root/work/vec4k
L=/root/work/verify_4k.log
mkdir -p $D $V
: > $L
log() { echo "$*" | tee -a $L; }
sum() {  # sum the summary lines of tb_gdf over several runs
  grep '^segments' | awk -F', ' '{ for (i = 1; i <= NF; i++) { k = $i; sub(/ [0-9]+$/, "", k);
    v = $i; sub(/.* /, "", v); if (!(k in s)) o[++m] = k; s[k] += v } }
    END { for (j = 1; j <= m; j++) printf "%s%s %d", (j > 1 ? ", " : ""), o[j], s[o[j]]; print "" }'
}

if [ -z "${SKIP_DECODE:-}" ]; then   # SKIP_DECODE=1: reuse the dumps (RTL-only rerun)
log "== decode $(date +%T)"
BIT=$B OUT=$R/data/profile_4k DUMPDIR=$D AVM_GDF_DUMP_MAXFRAMES=10 JOBS=4 \
  bash $R/scripts/decode_all.sh 1 >> $L 2>&1
for bs in $B/*.obu; do
  n=$(basename $bs .obu)
  AVM_LR_DUMP=$D/$n.lrdump /root/build/avm-instr/avmdec $bs --noblit --threads=1 >/dev/null 2>&1 &
done
wait
ls -la $D | tee -a $L

log "== golden $(date +%T)"
python3 $R/analysis/gdf_golden.py $D/*.gdfdump 2>&1 | tail -2 | tee -a $L
python3 $R/analysis/lr_golden.py --classify $D/*.lrdump 2>&1 | tail -16 | tee -a $L
fi

log "== RTL GDF units $(date +%T)"
python3 $R/tools/make_vectors.py $V/real_4k.vec $D/*.gdfdump | tee -a $L
python3 $R/tools/make_vectors.py $V/real_4k_fip.vec $D/*.gdfdump --fip | tee -a $L
log "VS m1:        $(VS=1 MSTG=1 bash $R/scripts/sim.sh $V/real_4k.vec 2>&1 | tail -1)"
log "JOINT m1:     $(VS=1 PCW=1 LR=1 MSTG=1 bash $R/scripts/sim.sh $V/real_4k.vec 2>&1 | tail -1)"
log "VS FIP m2:    $(VS=1 FIP=1 MSTG=2 bash $R/scripts/sim.sh $V/real_4k_fip.vec 2>&1 | tail -1)"
log "JOINT FIP m2: $(VS=1 PCW=1 LR=1 FIP=1 MSTG=2 bash $R/scripts/sim.sh $V/real_4k_fip.vec 2>&1 | tail -1)"

log "== RTL LR units, multi-unit LR segments, joint units $(date +%T)"
for m in "1 0" "2 0" "2 1"; do
  set -- $m
  fip=(); [ $2 = 1 ] && fip=(--fip)
  for l in $D/*.lrdump; do
    n=$(basename $l .lrdump)
    python3 $R/tools/make_lr_vectors.py $V/lr_$n.vec $l > /dev/null
    VS=1 PCW=1 LR=1 MSTG=$1 FIP=$2 bash $R/scripts/sim.sh $V/lr_$n.vec 2>&1 | tail -1
  done | sum | sed "s/^/LR units m$1 fip$2: /" | tee -a $L
  for l in $D/*.lrdump; do
    n=$(basename $l .lrdump)
    python3 $R/tools/make_lr_vectors.py $V/st_$n.vec $l --stripes > /dev/null
    MAXCH=256 AW=8 VS=1 PCW=1 LR=1 MSTG=$1 FIP=$2 bash $R/scripts/sim.sh $V/st_$n.vec 2>&1 | tail -1
  done | sum | sed "s/^/LR stripes m$1 fip$2: /" | tee -a $L
  for g in $D/*.gdfdump; do
    n=$(basename $g .gdfdump)
    [ -f $D/$n.lrdump ] || continue
    off=(); [ -s $D/$n.gdfoff ] && off=(--off $D/$n.gdfoff)      # units with GDF off
    python3 $R/tools/make_joint_vectors.py $V/jt_$n.vec $g $D/$n.lrdump "${off[@]}" "${fip[@]}" >> $L
    VS=1 PCW=1 LR=1 MSTG=$1 FIP=$2 bash $R/scripts/sim.sh $V/jt_$n.vec 2>&1 | tail -1
  done | sum | sed "s/^/joint units m$1 fip$2: /" | tee -a $L
  for g in $D/*.gdfdump; do
    n=$(basename $g .gdfdump)
    [ -f $D/$n.lrdump ] || continue
    off=(); [ -s $D/$n.gdfoff ] && off=(--off $D/$n.gdfoff)      # units with GDF off
    python3 $R/tools/make_wide_vectors.py $V/wide_$n.vec $g $D/$n.lrdump "${off[@]}" "${fip[@]}" >> $L
    python3 $R/tools/make_wide_vectors.py $V/split_$n.vec $g $D/$n.lrdump --split 1920 "${off[@]}" "${fip[@]}" >> $L
    MAXCH=1024 AW=10 VS=1 PCW=1 LR=1 MSTG=$1 FIP=$2 bash $R/scripts/sim.sh $V/wide_$n.vec 2>&1 | tail -1
    MAXCH=1024 AW=10 VS=1 PCW=1 LR=1 MSTG=$1 FIP=$2 bash $R/scripts/sim.sh $V/split_$n.vec 2>&1 | tail -1
  done | sum | sed "s/^/wide+split m$1 fip$2: /" | tee -a $L
done
log "VERIFY_4K_DONE $(date +%T)"
