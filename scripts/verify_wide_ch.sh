#!/usr/bin/env bash
# Complete joint stage on full-width stripes: the GDF units of every stripe of
# every LR-enabled stream (with GDF on or off: .gdfoff), the luma LR units of
# the stripe in the four coefficient banks, reloaded during the segment, and
# the chroma of the stripe (.lrcdump and .lrcoff: units with and without LR,
# up to four filters per plane), tools/make_wide_vectors.py --lrc.  Luma y,
# GDF error and correction, U and V against the reference decoder, for the
# ASIC pipeline (MSTG = 1) and the FPGA pipeline without and with the fast
# inner product.
# Log: /root/work/verify_wide_ch.log
set -uo pipefail
R=/mnt/g/AV2
V=/root/work/vec_wch
L=/root/work/verify_wide_ch.log
mkdir -p $V
: > $L
sum() {  # sum the summary lines of tb_gdf over several runs
  grep '^segments' | awk -F', ' '{ for (i = 1; i <= NF; i++) { k = $i; sub(/ [0-9]+$/, "", k);
    v = $i; sub(/.* /, "", v); if (!(k in s)) o[++m] = k; s[k] += v } }
    END { for (j = 1; j <= m; j++) printf "%s%s %d", (j > 1 ? ", " : ""), o[j], s[o[j]]; print "" }'
}
python3 $R/tools/make_pcw_rom.py >/dev/null
for m in "1 0" "2 0" "2 1"; do
  set -- $m
  fip=(); [ $2 = 1 ] && fip=(--fip)
  for g in /root/work/dumps_lr/*.gdfdump /root/work/dumps_4k/*.gdfdump; do
    n=$(basename "$g" .gdfdump)
    l=${g%.gdfdump}.lrdump; c=/root/work/dumps_lrc/$n.lrcdump
    [ -f "$l" ] && [ -f "$c" ] || continue
    off=(); [ -s "${g%.gdfdump}.gdfoff" ] && off=(--off "${g%.gdfdump}.gdfoff")
    python3 $R/tools/make_wide_vectors.py $V/w_$n.vec "$g" "$l" "${off[@]}" --lrc "$c" "${fip[@]}" | sed "s/^/m$1 fip$2 /" >> $L
    MAXCH=1024 AW=10 VS=1 PCW=1 LR=1 CH=1 MSTG=$1 FIP=$2 bash $R/scripts/sim.sh $V/w_$n.vec 2>&1 | tail -1
  done | sum | sed "s/^/wide + chroma m$1 fip$2: /" | tee -a $L
done
python3 - $L <<'EOF' | tee -a $L
import re, sys
tot = {}
for line in open(sys.argv[1]):
    m = re.match(r"m1 fip0 wrote .*: (\{.*\})", line)
    if m:
        for k, v in eval(m.group(1)).items():
            tot[k] = tot.get(k, 0) + v
print("stripes (m1):", {k: tot.get(k, 0) for k in ("stripes", "rus", "reloads", "goff", "mixed", "chroma", "chroma_samples", "chroma_rus")})
EOF
[ "$(grep -c '^wide + chroma .*mismatches 0,' $L)" = 3 ] && echo VERIFY_WIDE_CH_PASS | tee -a $L || echo VERIFY_WIDE_CH_FAIL | tee -a $L
