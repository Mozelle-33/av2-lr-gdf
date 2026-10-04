#!/usr/bin/env bash
# Self-test ROMs for the joint LR/GDF core with a full-width 4K stripe:
# 20 GDF units with their LR stripes from each of five LR bitstreams (8/10
# bit, intra/inter, PC-Wiener and Wiener-NS, LR off), four segments over
# several restoration units, and one 3,840-column stripe of the 4K bitstream
# (Crosswalk, 10 bit) whose 15 restoration units (PC-Wiener and Wiener-NS)
# need 11 coefficient-bank reloads during the segment.  Then a Verilator run
# of gdf_selftest (2 loops, then 2 loops with error injection).
# Usage: [FIP=0|1] rom_joint4k.sh [outdir]
set -euo pipefail
ROOT=/mnt/g/AV2
F=${FIP:-1}
OUT=${1:-/root/work/rom_joint4k_f$F}
V=/root/work/pnr/romvec; mkdir -p $V $OUT
FIPARG=(); [ "$F" = 1 ] && FIPARG=(--fip)
vecs=()
for n in KristenAndSara_1280x720_60_ai_q110_s2_f2 RollerCoaster_1280x720p_5994_10bit_420_ai_q160_s2_f2 \
         BlueSky_360p25_v2_ra_q135_s2_f17 Stockholm_640x360_5994_ra_q185_s2_f17 RedKayak_360_2997_ai_q210_s2_f4; do
  python3 $ROOT/tools/make_joint_vectors.py $V/$n.f$F.m20.vec /root/work/dumps_lr/$n.gdfdump \
    /root/work/dumps_lr/$n.lrdump "${FIPARG[@]}" --max 20 | tail -1
  vecs+=($V/$n.f$F.m20.vec)
done
python3 $ROOT/tools/make_lr_vectors.py $V/stripes.vec /root/work/dumps_lr/BlueSky_360p25_v2_ra_q135_s2_f17.lrdump \
  --stripes --max 4 | tail -1
vecs+=($V/stripes.vec)
n4=Crosswalk_3840x2160_5994fps_10bit_420_f10_ai_q160_s2_f2
python3 $ROOT/tools/make_wide_vectors.py $V/wide4k.f$F.vec /root/work/dumps_4k/$n4.gdfdump \
  /root/work/dumps_4k/$n4.lrdump "${FIPARG[@]}" --only 38 | tail -1
vecs+=($V/wide4k.f$F.vec)
python3 $ROOT/tools/make_rom_joint.py $OUT "${vecs[@]}"
VS=1 LR=1 FIP=$F bash $ROOT/scripts/sim_selftest.sh $OUT 2
VS=1 LR=1 FIP=$F bash $ROOT/scripts/sim_selftest.sh $OUT 2 1
