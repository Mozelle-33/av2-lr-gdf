#!/usr/bin/env bash
# Bit-exactness of the ablation variants (MACF, IDXF, LA) of gdf_core.
#   V0 conventional      MACF=1 IDXF=1 LA=0
#   V1 + supports/swap   MACF=0 IDXF=1 LA=0
#   V2 + mult-free index MACF=0 IDXF=0 LA=0
#   V3 + look-ahead      MACF=0 IDXF=0 LA=1  (proposed)
set -uo pipefail
cd /root/work
V=/root/work/vec
if [ ! -f $V/stress_stripe_idx.vec ]; then
  python3 /mnt/g/AV2/tools/make_vectors.py $V/stress_stripe_idx.vec /root/work/stress_stripe.bin --idx-full
fi
run() {  # macf idxf la vec
  r=$(MACF=$1 IDXF=$2 LA=$3 bash /mnt/g/AV2/scripts/sim.sh $4 2>&1 | tail -1)
  echo "MACF=$1 IDXF=$2 LA=$3 $(basename $4): $r"
}
run 1 1 0 $V/stress_stripe_full.vec
run 0 1 0 $V/stress_stripe_idx.vec
run 0 0 0 $V/stress_stripe.vec
run 0 1 1 $V/stress_stripe_idx.vec
run 1 1 1 $V/stress_stripe_full.vec
run 0 0 1 $V/stress_stripe.vec
if [ "${1:-}" = "real" ]; then
  run 0 0 0 $V/real_all.vec
  run 1 1 0 $V/real_all_full.vec
fi
# fast inner product (FIP), FPGA and ASIC multiplier pipelines
if [ ! -f $V/stress_stripe_fip.vec ]; then
  python3 /mnt/g/AV2/tools/make_vectors.py $V/stress_stripe_fip.vec /root/work/stress_stripe.bin --fip
fi
r=$(FIP=1 bash /mnt/g/AV2/scripts/sim.sh $V/stress_stripe_fip.vec 2>&1 | tail -1); echo "FIP=1 MSTG=2 stress: $r"
r=$(FIP=1 MSTG=1 bash /mnt/g/AV2/scripts/sim.sh $V/stress_stripe_fip.vec 2>&1 | tail -1); echo "FIP=1 MSTG=1 stress: $r"
if [ "${1:-}" = "real" ]; then
  [ -f $V/real_all_fip.vec ] || python3 /mnt/g/AV2/tools/make_vectors.py $V/real_all_fip.vec /root/work/dumps/*.gdfdump /root/work/dumps_lr/*.gdfdump --fip
  r=$(FIP=1 bash /mnt/g/AV2/scripts/sim.sh $V/real_all_fip.vec 2>&1 | tail -1); echo "FIP=1 MSTG=2 real: $r"
fi
