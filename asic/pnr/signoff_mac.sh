#!/usr/bin/env bash
# Sign-off reports of a routed run with macros: the three corners
# (corners_mac.tcl), the typical corner of the flow (signoff_check.tcl) and the
# start points of the worst setup paths (worst_starts.tcl).
# Usage: [MACRO_DIR=dir] [MACRO_CORNERS=dir] signoff_mac.sh <tag>
set -uo pipefail
R=/root/work/pnr/$1
P=/mnt/g/AV2/asic/pnr
export RUN=$R SDC=$P/gdf_mac.sdc PERIOD=2.5
export MACRO_DIR=${MACRO_DIR:-/root/work/macros} MACRO_CORNERS=${MACRO_CORNERS:-/root/work/macros_corners}
cd $R
openroad -no_init -exit $P/corners_mac.tcl > $R/corners.log 2>&1
openroad -no_init -exit $P/signoff_check.tcl > $R/signoff.log 2>&1
N=300 openroad -no_init -exit $P/worst_starts.tcl > $R/worst_starts.log 2>&1
echo SIGNOFF_MAC_DONE >> $R/signoff.log
