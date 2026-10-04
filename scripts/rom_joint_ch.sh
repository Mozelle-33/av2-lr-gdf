#!/usr/bin/env bash
# Self-test ROMs for the joint stage with the chroma LR (CH = 1, FPGA pipeline
# with the fast inner product): GDF units with their LR stripes and the chroma
# of their region (type 7; units without a chroma stripe run with the chroma
# off) from five bitstreams (8/10 bit, intra/inter, 360p/720p/4K), and chroma
# stripe segments (type 6) with the down-sampling filters 0 and 2 and with
# 10-bit samples.  Then a Verilator run of gdf_selftest (2 loops, then 2
# loops with error injection).
# Usage: rom_joint_ch.sh [outdir]
set -euo pipefail
ROOT=/mnt/g/AV2
OUT=${1:-/root/work/rom_joint_ch}
V=/root/work/pnr/romvec_ch; mkdir -p $V $OUT
vecs=()
mk() {  # name, dir, max units
  local n=$1 d=$2 m=$3
  python3 $ROOT/tools/make_joint_vectors.py $V/$n.m$m.vec $d/$n.gdfdump $d/$n.lrdump \
    --lrc /root/work/dumps_lrc/$n.lrcdump --fip --max $m | tail -1
  vecs+=($V/$n.m$m.vec)
}
mk KristenAndSara_1280x720_60_ai_q110_s2_f2 /root/work/dumps_lr 16
mk RollerCoaster_1280x720p_5994_10bit_420_ai_q160_s2_f2 /root/work/dumps_lr 10
mk BlueSky_360p25_v2_ra_q135_s2_f17 /root/work/dumps_lr 8
mk Stockholm_640x360_5994_ai_q110_s2_f4 /root/work/dumps_lr 8
mk Crosswalk_3840x2160_5994fps_10bit_420_f10_ai_q110_s2_f2 /root/work/dumps_4k 8
# chroma stripe segments: the first segments of the forced-filter streams
for n in BlueSky_360p25_v2_ai_q110_ds0 BlueSky_360p25_v2_ai_q110_ds2 RollerCoaster_1280x720p_5994_10bit_420_ai_q110_ds2; do
  python3 $ROOT/tools/make_lrc_vectors.py $V/$n.vec /root/work/dumps_lrc_ds/$n.lrcdump | tail -1
  python3 - "$V/$n.vec" "$V/$n.s3.vec" <<'EOF'
import sys
sys.path.insert(0, "/mnt/g/AV2/tools")
from split_vec import records
buf = open(sys.argv[1], "rb").read()
out, segs = [buf[:8]], 0
for t, s, e, w in records(buf, 8):
    if t not in (1, 5):
        if segs == 3:
            break
        segs += 1
    out.append(buf[s:e])
out.append(b"\x00")
open(sys.argv[2], "wb").write(b"".join(out))
EOF
  vecs+=($V/$n.s3.vec)
done
python3 $ROOT/tools/make_rom_joint.py $OUT --ch "${vecs[@]}"
VS=1 LR=1 CH=1 FIP=1 bash $ROOT/scripts/sim_selftest.sh $OUT 2
VS=1 LR=1 CH=1 FIP=1 bash $ROOT/scripts/sim_selftest.sh $OUT 2 1
