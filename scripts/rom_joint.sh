#!/usr/bin/env bash
# Self-test ROMs for the joint LR/GDF core: 30 GDF units with their LR stripes
# from each of five LR bitstreams (8/10 bit, intra/inter, PC-Wiener and
# Wiener-NS, LR off), then a Verilator run of gdf_selftest (2 loops, then 2
# loops with error injection from loop 2).  Usage: [FIP=0|1] rom_joint.sh [outdir]
set -euo pipefail
ROOT=/mnt/g/AV2
OUT=${1:-/root/work/rom_joint_f${FIP:-0}}
V=/root/work/pnr/romvec; mkdir -p $V $OUT
FIPARG=(); [ "${FIP:-0}" = 1 ] && FIPARG=(--fip)
vecs=()
for n in KristenAndSara_1280x720_60_ai_q110_s2_f2 RollerCoaster_1280x720p_5994_10bit_420_ai_q160_s2_f2 \
         BlueSky_360p25_v2_ra_q135_s2_f17 Stockholm_640x360_5994_ra_q185_s2_f17 RedKayak_360_2997_ai_q210_s2_f4; do
  python3 $ROOT/tools/make_joint_vectors.py $V/$n.f${FIP:-0}.vec /root/work/dumps_lr/$n.gdfdump \
    /root/work/dumps_lr/$n.lrdump "${FIPARG[@]}" --max 30 | tail -1
  vecs+=($V/$n.f${FIP:-0}.vec)
done
# four segments over several restoration units (coefficient banks switched
# within the segment)
python3 $ROOT/tools/make_lr_vectors.py $V/stripes.vec /root/work/dumps_lr/BlueSky_360p25_v2_ra_q135_s2_f17.lrdump \
  --stripes --max 4 | tail -1
vecs+=($V/stripes.vec)
python3 $ROOT/tools/make_rom_joint.py $OUT "${vecs[@]}"
VS=1 LR=1 FIP=${FIP:-0} bash $ROOT/scripts/sim_selftest.sh $OUT 2
VS=1 LR=1 FIP=${FIP:-0} bash $ROOT/scripts/sim_selftest.sh $OUT 2 1
