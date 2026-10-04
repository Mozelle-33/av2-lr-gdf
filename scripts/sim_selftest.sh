#!/usr/bin/env bash
# Build and run the Verilator model of gdf_selftest on a ROM directory.
# Usage: sim_selftest.sh <romdir> [loops] [inject]
set -euo pipefail
ROOT=/mnt/g/AV2
ROM=$(realpath "$1"); shift
P() { sed -n "s/^localparam $1 = \([0-9]*\);/\1/p" "$ROM/rom_params.vh"; }
OBJ=/root/work/sim/obj_selftest_f${FIP:-0}_v${VS:-0}_l${LR:-0}_h${CH:-0}
mkdir -p "$OBJ"
verilator --cc "$ROOT/rtl/gdf_core.v" "$ROOT/rtl/gdf_selftest.v" --top-module gdf_selftest \
  --exe "$ROOT/tb/tb_selftest.cpp" -O3 -Wno-fatal -Wno-lint -Wno-style \
  -GCMD_N=$(P CMD_N) -GCMD_AW=$(P CMD_AW) -GCMD_NB=$(P CMD_NB) \
  -GIN_N=$(P IN_N) -GIN_AW=$(P IN_AW) -GIN_NB=$(P IN_NB) \
  -GMAXCH=1024 -GAW=10 -GFIP=${FIP:-0} -GVS=${VS:-0} -GLR=${LR:-0} -GCH=${CH:-0} \
  -GPCWROM="\"$ROOT/rtl/pcw_class.hex\"" -GLRSEL="\"$ROOT/rtl/pcw_sel.hex\"" \
  -Mdir "$OBJ" --build -j 16 >"$OBJ/build.log" 2>&1 || {
    grep -E "%Error|error" "$OBJ/build.log" | head -40; exit 1; }
cd "$ROM"
"$OBJ/Vgdf_selftest" "$@"
