#!/usr/bin/env bash
# RTL simulation of the ASIC configuration of the joint stage (VS = 1, PCW = 1,
# LR = 1, CH = 1, MSTG = 1, 1024 strips) with the RAM modules replaced by the
# macro wrappers of mem_macros.v and the macro models of asic/macros, i.e. the
# memories of the layout (pnr_mac.tcl), against the vectors of the RTL.
# Usage: [ROM_MACRO=1] [MACRO_DIR=dir] sim_rtl_mac.sh <file.vec>...
#   ROM_MACRO=1: the PC-Wiener class ROM as the macro of mem_macros_rom.v
set -euo pipefail
ROOT=/mnt/g/AV2
M=${MACRO_DIR:-/root/work/macros}
OBJ=/root/work/sim/obj_asic_mac${ROM_MACRO:+_rom}
mkdir -p $OBJ
if [ ! -x $OBJ/Vgdf_core ] || [ $ROOT/rtl/gdf_core.v -nt $OBJ/Vgdf_core ] || \
   [ $ROOT/asic/pnr/mem_macros.v -nt $OBJ/Vgdf_core ] || [ $ROOT/tb/tb_gdf.cpp -nt $OBJ/Vgdf_core ]; then
  python3 - $ROOT/rtl/gdf_core.v $OBJ/gdf_core_nomem.v <<'EOF'
import re, sys
t = open(sys.argv[1]).read()
import os
for m in ["gdf_ram_sdp", "gdf_ram_lut"] + (["gdf_rom_pcw"] if os.environ.get("ROM_MACRO") == "1" else []):
    a = re.search(r"^module %s\b" % m, t, re.M).start()
    b = t.index("endmodule", a) + len("endmodule")
    t = t[:a] + t[b:]
open(sys.argv[2], "w").write(t)
EOF
  if [ "${ROM_MACRO:-0}" = 1 ]; then
    models="$(ls $M/*/fakeram45_*.v | grep -v '\.bb\.v$') $ROOT/asic/pnr/mem_macros_rom.v"
  else
    models=$(ls $M/*/fakeram45_*.v | grep -v '\.bb\.v$' | grep -v '_rom_')
  fi
  verilator --cc $OBJ/gdf_core_nomem.v $ROOT/asic/pnr/mem_macros.v $models --top-module gdf_core \
    --exe $ROOT/tb/tb_gdf.cpp -O3 -Wno-fatal -Wno-lint -Wno-style \
    -GMAXCH=1024 -GAW=10 -GMSTG=1 -GMACF=0 -GIDXF=0 -GLA=1 -GFIP=0 -GVS=1 -GNB=1 -GGC=4 \
    -GPCW=1 -GLR=1 -GCH=1 -GPCWROM="\"$ROOT/rtl/pcw_class.hex\"" -GLRSEL="\"$ROOT/rtl/pcw_sel.hex\"" \
    -CFLAGS "-DGDF_NB=1 -DGDF_GC=4" -Mdir $OBJ --build -j 16 > $OBJ/build.log 2>&1 || {
      grep -E "%Error|error" $OBJ/build.log | head -20; exit 1; }
fi
for v in "$@"; do
  echo "== $(basename $v)"
  GDF_VS=1 $OBJ/Vgdf_core $v | tail -1
done
