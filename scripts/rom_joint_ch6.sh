#!/usr/bin/env bash
# Self-test ROMs of the final joint stage with the chroma LR (CH = 1, FPGA
# pipeline with the fast inner product, GDF side stream in_gdf):
#   * a full-width stripe of the 10-bit 4K intra frame with its chroma (15
#     luma restoration units in the four coefficient banks, 11 reloads during
#     the segment, 15 chroma restoration units),
#   * a full-width stripe of the 720p intra frame with blocks with GDF on and
#     off and its chroma,
#   * GDF units with their LR stripes and the chroma of their region from four
#     bitstreams (8/10 bit, intra/inter, 360p/720p),
#   * chroma stripe segments with the down-sampling filters 0 and 2 and with
#     10-bit samples,
#   * units of the luma LR stress set.
# Then a Verilator run of gdf_selftest (2 loops, then 2 loops with error
# injection).
# Usage: rom_joint_ch6.sh [outdir]
set -euo pipefail
ROOT=/mnt/g/AV2
OUT=${1:-/root/work/rom_joint_ch6}
V=/root/work/pnr/romvec_ch6; mkdir -p $V $OUT
C=/root/work/dumps_lrc
vecs=()
n=Crosswalk_3840x2160_5994fps_10bit_420_f10_ai_q110_s2_f2; d=/root/work/dumps_4k
python3 $ROOT/tools/make_wide_vectors.py $V/wide_xw.vec $d/$n.gdfdump $d/$n.lrdump --off $d/$n.gdfoff \
  --lrc $C/$n.lrcdump --fip --only 4 | tail -1
vecs+=($V/wide_xw.vec)
n=KristenAndSara_1280x720_60_ai_q110_s2_f2; d=/root/work/dumps_lr
python3 $ROOT/tools/make_wide_vectors.py $V/wide_ks_off.vec $d/$n.gdfdump $d/$n.lrdump --off $d/$n.gdfoff \
  --lrc $C/$n.lrcdump --fip --mixed --max 1 | tail -1
vecs+=($V/wide_ks_off.vec)
mk() {  # name, dir, max units
  local n=$1 d=$2 m=$3
  python3 $ROOT/tools/make_joint_vectors.py $V/$n.m$m.vec $d/$n.gdfdump $d/$n.lrdump \
    --lrc $C/$n.lrcdump --fip --max $m | tail -1
  vecs+=($V/$n.m$m.vec)
}
mk KristenAndSara_1280x720_60_ai_q110_s2_f2 /root/work/dumps_lr 6
mk RollerCoaster_1280x720p_5994_10bit_420_ai_q160_s2_f2 /root/work/dumps_lr 4
mk BlueSky_360p25_v2_ra_q135_s2_f17 /root/work/dumps_lr 4
mk Stockholm_640x360_5994_ai_q110_s2_f4 /root/work/dumps_lr 2
# chroma stripe segments: the first segments of the forced-filter streams
first() {  # in.vec out.vec segments
  python3 - "$1" "$2" "$3" <<'EOF'
import sys
sys.path.insert(0, "/mnt/g/AV2/tools")
from split_vec import records
buf = open(sys.argv[1], "rb").read()
out, pend, segs = [buf[:8]], [], 0
for t, s, e, w in records(buf, 8):
    pend.append(buf[s:e])
    if t not in (1, 5):                 # a segment: keep it with its writes
        if segs == int(sys.argv[3]):
            break
        segs += 1
        out += pend
        pend = []
out.append(b"\x00")
open(sys.argv[2], "wb").write(b"".join(out))
EOF
}
for n in BlueSky_360p25_v2_ai_q110_ds0 BlueSky_360p25_v2_ai_q110_ds2 RollerCoaster_1280x720p_5994_10bit_420_ai_q110_ds2; do
  python3 $ROOT/tools/make_lrc_vectors.py $V/$n.vec /root/work/dumps_lrc_ds/$n.lrcdump | tail -1
  first $V/$n.vec $V/$n.s2.vec 2
  vecs+=($V/$n.s2.vec)
done
python3 $ROOT/tools/make_lr_vectors.py $V/lr_stress.vec /root/work/lrstress/lr_stress.lrdump --max 6 | tail -1
vecs+=($V/lr_stress.vec)
python3 $ROOT/tools/make_rom_joint.py $OUT --ch "${vecs[@]}"
VS=1 LR=1 CH=1 FIP=1 bash $ROOT/scripts/sim_selftest.sh $OUT 2
VS=1 LR=1 CH=1 FIP=1 bash $ROOT/scripts/sim_selftest.sh $OUT 2 1
