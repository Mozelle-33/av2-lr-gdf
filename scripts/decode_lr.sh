#!/usr/bin/env bash
# Decode the LR-enabled bitstreams with the instrumented AVM decoder and dump
# every luma LR stripe of a restoration unit (AVM_LR_DUMP, see tcas_instr.h).
set -uo pipefail
INS=/root/build/avm-instr/avmdec
OUT=/root/work/dumps_lr
mkdir -p $OUT
for bs in /root/work/bit_lr/*.obu; do
  name=$(basename "$bs" .obu)
  AVM_LR_DUMP=$OUT/$name.lrdump nice -n 5 $INS "$bs" --noblit --threads=1 >/dev/null 2>&1 &
  while [ $(jobs -r | wc -l) -ge 12 ]; do sleep 1; done
done
wait
ls -la $OUT | awk '{s += $5} END {print "total bytes", s}'
ls $OUT | wc -l
echo DECODE_LR_DONE
