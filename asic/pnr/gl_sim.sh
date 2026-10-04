#!/usr/bin/env bash
# Gate-level simulation of a routed column-major gdf_core (P = 8) with
# Verilator, driven by tb/tb_gdf.cpp.  TRACE=1 builds with VCD support.
# Usage: [TRACE=1] gl_sim.sh <tag> <file.vec> [tb args]; GDF_VCD* env for the window
set -euo pipefail
tag=$1; vec=$2; shift 2
D=/root/work/pnr/$tag/gl; mkdir -p $D
[ -f $D/gl_wrap.v ] || python3 /mnt/g/AV2/asic/pnr/gl_wrap.py /root/work/pnr/$tag/final.v $D
T=${TRACE:-0}
OBJ=$D/obj_t$T
if [ ! -x $OBJ/Vgdf_core ]; then
  # nets of the routed netlist (TOP.gdf_core.u_pnr), not the nets inside cells
  # (the cell models carry "verilator tracing_off")
  tr=""; cells=/root/work/pnr/gl/nangate45_cells.v
  [ "$T" = 1 ] && { tr="--trace --trace-underscore"; cells=/root/work/pnr/gl/nangate45_cells_notrace.v; }
  echo "verilating $(date +%T)"
  verilator --cc $D/gl_wrap.v $D/gdf_core_pnr.v $D/gl_rams.v $cells \
    --top-module gdf_core --exe /mnt/g/AV2/tb/tb_gdf.cpp $tr \
    -Wno-fatal -Wno-lint -Wno-style -Wno-UNOPTFLAT --output-split 20000 \
    -CFLAGS "-DGDF_NB=1 -DGDF_GC=4 -O1" -Mdir $OBJ --build -j ${GLJ:-24} > $D/build_t$T.log 2>&1 || {
      grep -E "%Error|error:" $D/build_t$T.log | head -20; exit 1; }
  echo "built $(date +%T)"
fi
GDF_VS=1 $OBJ/Vgdf_core "$vec" "$@"
