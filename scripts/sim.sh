#!/usr/bin/env bash
# Build the Verilator model of gdf_core and run a vector file.
# Usage: [FULL=1] [MSTG=1] [MACF=0|1] [IDXF=0|1] [LA=0|1] [FIP=0|1] [VS=0|1]
#        [NB=1|2] [GC=4|2] [PCW=0|1] [LR=0|1] [CH=0|1] sim.sh <file.vec> [-v]
#   FULL sets MACF and IDXF unless they are given; rebuilds when rtl/tb changed.
#   VS=1 builds the column-major core and feeds the words chunk-major;
#   NB/GC (VS=1 only) set the parallelism: 2*NB*GC samples per cycle.
set -euo pipefail
ROOT=/mnt/g/AV2
FULL=${FULL:-0}
MSTG=${MSTG:-2}
MACF=${MACF:-$FULL}
IDXF=${IDXF:-$FULL}
LA=${LA:-1}
FIP=${FIP:-0}
VS=${VS:-0}
NB=${NB:-1}
GC=${GC:-4}
PCW=${PCW:-0}
LR=${LR:-0}
CH=${CH:-0}
MAXCH0=32; AW0=5
[ "$GC" = 2 ] && { MAXCH0=64; AW0=6; }    # 2-column chunks: twice as many
MAXCH=${MAXCH:-$MAXCH0}; AW=${AW:-$AW0}  # wider segments: MAXCH=256 AW=8
OBJ=/root/work/sim/obj_m${MACF}_i${IDXF}_la${LA}_f${FIP}_s${MSTG}_v${VS}_b${NB}_c${GC}_p${PCW}_l${LR}_h${CH}_w${MAXCH}
mkdir -p "$OBJ"
if [ ! -x "$OBJ/Vgdf_core" ] || [ "$ROOT/rtl/gdf_core.v" -nt "$OBJ/Vgdf_core" ] || \
   [ "$ROOT/tb/tb_gdf.cpp" -nt "$OBJ/Vgdf_core" ]; then
  verilator --cc "$ROOT/rtl/gdf_core.v" --top-module gdf_core \
    --exe "$ROOT/tb/tb_gdf.cpp" -O3 -Wno-fatal -Wno-lint -Wno-style \
    -GMAXCH=$MAXCH -GAW=$AW -GMSTG=$MSTG -GMACF=$MACF -GIDXF=$IDXF -GLA=$LA -GFIP=$FIP \
    -GVS=$VS -GNB=$NB -GGC=$GC -GPCW=$PCW -GLR=$LR -GCH=$CH -GPCWROM="\"$ROOT/rtl/pcw_class.hex\"" \
    -GLRSEL="\"$ROOT/rtl/pcw_sel.hex\"" \
    -CFLAGS "-DGDF_NB=$NB -DGDF_GC=$GC" \
    -Mdir "$OBJ" --build -j 16 >"$OBJ/build.log" 2>&1 || {
      grep -E "%Error|error" "$OBJ/build.log" | head -40; exit 1; }
fi
GDF_VS=$VS "$OBJ/Vgdf_core" "$@"
