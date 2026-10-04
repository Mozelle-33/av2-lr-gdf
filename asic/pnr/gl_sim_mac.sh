#!/usr/bin/env bash
# Gate-level simulation of a routed gdf_core with its SRAM macros (pnr_mac.tcl)
# with Verilator, driven by tb/tb_gdf.cpp: the routed netlist has the RTL
# interface, the macros are simulated by their Verilog models
# (asic/macros/gen_gdf_macros.py).  TRACE=1 builds with VCD support (nets of
# the netlist, TOP.gdf_core; neither the cells nor the macro arrays).
# Usage: [TRACE=1] gl_sim_mac.sh <tag> <file.vec> [tb args]; GDF_VCD* env for the window
set -euo pipefail
tag=$1; vec=$2; shift 2
R=/root/work/pnr/$tag
D=$R/gl; mkdir -p $D
M=${MACRO_DIR:-/root/work/macros}
T=${TRACE:-0}
OBJ=$D/obj_t$T
if [ ! -x $OBJ/Vgdf_core ]; then
  tr=""; cells=/root/work/pnr/gl/nangate45_cells.v
  [ "$T" = 1 ] && { tr="--trace --trace-underscore"; cells=/root/work/pnr/gl/nangate45_cells_notrace.v; }
  # macro models, without tracing
  { echo "// verilator tracing_off"; for f in $(ls $M/*/fakeram45_*.v | grep -v '\.bb\.v$'); do cat $f; done; } > $D/macros_notrace.v
  echo "verilating $(date +%T)"
  ulimit -s unlimited          # verilator_bin recurses deeply on the flat netlist
  verilator --cc $R/final.v $D/macros_notrace.v $cells \
    --top-module gdf_core --exe /mnt/g/AV2/tb/tb_gdf.cpp $tr \
    -Wno-fatal -Wno-lint -Wno-style -Wno-UNOPTFLAT --output-split 20000 \
    -CFLAGS "-DGDF_NB=1 -DGDF_GC=4 -O1" -Mdir $OBJ --build -j ${GLJ:-24} > $D/build_t$T.log 2>&1 || {
      grep -E "%Error|error:" $D/build_t$T.log | head -20; exit 1; }
  echo "built $(date +%T)"
fi
GDF_VS=1 $OBJ/Vgdf_core "$vec" "$@"
