#!/usr/bin/env bash
# Stress vectors of the luma and chroma LR (tools/make_lr_stress.py,
# tools/make_lrc_stress.py): random, extreme and structured samples, taps at
# the ends of the syntax ranges, all quantizer sets, 1 to 16 Wiener-NS filters,
# the three down-sampling filters, picture edges, bank switching and
# processing units with LR off; expected outputs from the bit-exact models.
# ASIC pipeline (MSTG = 1) and FPGA pipeline without and with the fast inner
# product.  Log: /root/work/verify_lr_stress.log
set -uo pipefail
R=/mnt/g/AV2
V=/root/work/lrstress
D=/root/work/dumps_lr
L=/root/work/verify_lr_stress.log
mkdir -p $V
: > $L
python3 $R/tools/make_pcw_rom.py >/dev/null
T="$D/BlueSky_360p25_v2_ai_q210_s2_f4.lrdump $D/RedKayak_360_2997_ra_q235_s2_f17.lrdump
  $D/RollerCoaster_1280x720p_5994_10bit_420_ai_q210_s2_f2.lrdump $D/BlueSky_360p25_v2_ra_q135_s2_f17.lrdump
  /root/work/dumps_4k/Crosswalk_3840x2160_5994fps_10bit_420_f10_ai_q210_s2_f2.lrdump"
# 2000 stripes, and 500 textured PC-Wiener stripes of quantizer set 0, which
# complete the coverage: with the bitstreams, all 256 classes and all 64
# filters of the four PC-Wiener banks are used (analysis/lr_coverage.py)
python3 $R/tools/make_lr_stress.py $V/lr_stress.lrdump ${NL:-2000} 77 $T | tee -a $L
python3 $R/tools/make_lr_stress.py $V/lr_stress_dir.lrdump 500 11 $T --set 0 --pcw 1 \
  --patterns grating,rand_amp,flat_noise,blocks,ramp | tee -a $L
python3 $R/analysis/lr_golden.py --classify $V/lr_stress.lrdump $V/lr_stress_dir.lrdump | grep -E "mismatch|RESULT|^set|^ncls" | tr '\n' ' ' | tee -a $L; echo | tee -a $L
python3 $R/analysis/lr_coverage.py stress $V/lr_stress.lrdump $V/lr_stress_dir.lrdump | tee -a $L
python3 $R/analysis/lr_coverage.py streams /root/work/dumps_lr/*.lrdump /root/work/dumps_4k/*.lrdump | tee -a $L
python3 $R/analysis/lr_coverage.py all /root/work/dumps_lr/*.lrdump /root/work/dumps_4k/*.lrdump $V/lr_stress.lrdump $V/lr_stress_dir.lrdump | tee -a $L
python3 $R/tools/make_lr_vectors.py $V/lr_stress_units.vec $V/lr_stress.lrdump $V/lr_stress_dir.lrdump | tee -a $L
python3 $R/tools/make_lr_vectors.py $V/lr_stress_stripes.vec $V/lr_stress.lrdump $V/lr_stress_dir.lrdump --stripes | tee -a $L
python3 $R/tools/make_lrc_stress.py $V/lrc_stress.vec ${NC:-800} 2026 | tee -a $L
bad=0
for cfg in "1 0" "2 0" "2 1"; do
  set -- $cfg
  for t in "luma units:lr_stress_units.vec:32:5:0" "luma segments:lr_stress_stripes.vec:256:8:0" "chroma segments:lrc_stress.vec:256:8:1"; do
    IFS=: read lab vec mch aw ch <<< "$t"
    r=$(VS=1 PCW=1 LR=1 CH=$ch MSTG=$1 FIP=$2 MAXCH=$mch AW=$aw bash $R/scripts/sim.sh $V/$vec 2>&1 | tail -1)
    echo "$lab m$1 fip$2: $r" | tee -a $L
    echo "$r" | grep -q "mismatches 0," || bad=1
  done
done
[ $bad = 0 ] && echo VERIFY_LR_STRESS_PASS | tee -a $L || echo VERIFY_LR_STRESS_FAIL | tee -a $L
