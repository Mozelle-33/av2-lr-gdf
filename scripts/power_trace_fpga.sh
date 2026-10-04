#!/usr/bin/env bash
# RTL port traces for the FPGA power of the joint stage (fpga/power/
# run_power_joint.ps1): the FPGA pipeline (MSTG = 2, fast inner product) of
# the luma joint stage (luma) or of the joint stage with the chroma LR (ch).
#   units (default): the 40 joint units of the KristenAndSara 720p intra frame
#     (FIP vectors, unchanged configuration writes dropped as for the ASIC
#     power window), 20,000 cycles from segment 2 + 20;
#   wide: two full-width stripes of that frame (stripes 4 and 5, GDF on in
#     every block; ch: with their chroma), 10,000 cycles from cycle 600 of the
#     first one, i.e., inside a stripe at 7.5 luma samples per cycle, the
#     window of asic/pnr/gl_joint_ch_r4.sh.
# Writes ports.hex / outs.hex (and cports.hex / couts.hex for ch),
# ports.hex.win and trace.vh into <dir>.
# Usage: power_trace_fpga.sh luma|ch <dir> [units|wide]
set -euo pipefail
ROOT=/mnt/g/AV2
G=/root/work/pnr/glvec
G4=/root/work/pnr/glvec_r4
KS=KristenAndSara_1280x720_60_ai_q110_s2_f2
D=/root/work/dumps_lr
mode=$1; out=$2; win=${3:-units}
mkdir -p $out $G4
if [ "$mode" = luma ]; then CHV=0; else CHV=1; fi
if [ "$win" = wide ]; then
  LRC=(); [ $CHV = 1 ] && LRC=(--lrc /root/work/dumps_lrc/$KS.lrcdump)
  vw=$G4/wide_ks2_fip_$mode.vec
  python3 $ROOT/tools/make_wide_vectors.py $vw $D/$KS.gdfdump $D/$KS.lrdump --off $D/$KS.gdfoff \
    "${LRC[@]}" --fip --from 4 --max 2 | tail -1
  export GDF_VCD_SEG=0 GDF_VCD_SKIP=600 GDF_VCD_LEN=10000
else
  if [ $CHV = 0 ]; then
    v=$G/joint_ks40_fip.vec; LRC=()
  else
    v=$G/joint_ch_ks40_fip.vec; LRC=(--lrc /root/work/dumps_lrc/$KS.lrcdump)
  fi
  vw=${v%.vec}_w.vec
  if [ ! -f $vw ]; then
    python3 $ROOT/tools/make_joint_vectors.py $v $D/$KS.gdfdump $D/$KS.lrdump "${LRC[@]}" --fip --max 40 | tail -1
    python3 $ROOT/tools/dedup_writes.py $v $vw | tail -1
  fi
  export GDF_VCD_SEG=2 GDF_VCD_SKIP=20 GDF_VCD_LEN=20000
fi
export FIP=1 VS=1 PCW=1 LR=1 CH=$CHV MSTG=2 MAXCH=1024 AW=10
export GDF_PORTDUMP=$out/ports.hex GDF_PORTDUMP_OUT=$out/outs.hex
if [ $CHV = 1 ]; then export GDF_PORTDUMP_C=$out/cports.hex GDF_PORTDUMP_COUT=$out/couts.hex; fi
bash $ROOT/scripts/sim.sh $vw 2>&1 | tail -3
read w0 len n < $out/ports.hex.win
printf '`define TRACE_N %d\n`define TRACE_WIN0 %d\n`define TRACE_WLEN %d\n' $n $w0 $len > $out/trace.vh
cat $out/trace.vh
wc -l $out/*.hex
