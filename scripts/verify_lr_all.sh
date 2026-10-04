#!/usr/bin/env bash
# Regression matrix of the joint LR/GDF core: LR-only vectors (all LR stripes)
# and end-to-end joint vectors (all GDF units of the LR streams), for the FPGA
# (MSTG=2) and ASIC (MSTG=1) pipelines and the fast inner product.
ROOT=/mnt/g/AV2
L=/root/work/verify_lr_all.log
: > $L
run() {  # label, env...
  local lab=$1; shift
  echo "== $lab" >> $L
  env "$@" bash $ROOT/scripts/${lab%%:*}.sh 2>&1 | tee -a $L | tail -1
}
run verify_joint:m2 MSTG=2
run verify_joint:m1 MSTG=1
run verify_joint:m2fip MSTG=2 FIP=1
run verify_lr:m1 MSTG=1
run verify_lr:m2fip MSTG=2 FIP=1
run verify_lr:m2 MSTG=2
echo LR_ALL_DONE >> $L
