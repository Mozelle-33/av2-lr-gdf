#!/usr/bin/env bash
# P&R of the column-major (VS) and row-major (V3) cores in parallel, then the
# sign-off reports.  Usage: run_both.sh [suffix]
P=/mnt/g/AV2/asic/pnr
s=${1:-}
bash $P/run_pnr.sh vs_u55$s 1 0 55 2.5 14 > /root/work/pnr/vs_u55$s.out 2>&1 &
sleep 30
bash $P/run_pnr.sh rm_u55$s 0 0 55 2.5 14 > /root/work/pnr/rm_u55$s.out 2>&1 &
wait
for t in vs_u55$s rm_u55$s; do
  echo "== $t"; grep -vE "^Warning" /root/work/pnr/$t.out | tail -12
  bash $P/run_report.sh $t
done
echo RUN_BOTH_DONE
