#!/usr/bin/env bash
# Synthesis + OpenROAD place and route of one gdf_core configuration with the
# SRAM macros in the layout (synth_mac.ys, pnr_mac.tcl).
# Usage: [PCW=0|1] [LR=0|1] [CH=0|1] [SYNTH_ONLY=1] [SKIP_SYNTH=1] [ROM_MACRO=1]
#        [MACRO_DIR=dir] [MACRO_ORDER=center]
#        run_pnr_mac.sh <tag> <VS> <FIP> [util=55] [period=2.5] [threads=12]
set -euo pipefail
tag=$1; vs=$2; fip=$3; util=${4:-55}; period=${5:-2.5}; thr=${6:-12}
P=/mnt/g/AV2/asic/pnr
M=${MACRO_DIR:-/root/work/macros}
plat=/root/work/pnr/orfs/flow/platforms/nangate45
out=/root/work/pnr/$tag; mkdir -p $out
lib=/root/work/pnr/nangate45_dontuse.lib
[ -f $lib ] || python3 $P/mark_dont_use.py $plat/lib/NangateOpenCellLibrary_typical.lib $lib \
  TAPCELL_X1 FILLCELL_X1 AOI211_X1 OAI211_X1
if [ "${SKIP_SYNTH:-0}" != 1 ]; then
  # the RTL without its RAM modules (mem_macros.v defines them with macros)
  python3 - /mnt/g/AV2/rtl/gdf_core.v $out/gdf_core_nomem.v <<'EOF'
import re, sys
t = open(sys.argv[1]).read()
import os
mods = ["gdf_ram_sdp", "gdf_ram_lut"] + (["gdf_rom_pcw"] if os.environ.get("ROM_MACRO") == "1" else [])
for m in mods:
    a = re.search(r"^module %s\b" % m, t, re.M).start()
    b = t.index("endmodule", a) + len("endmodule")
    t = t[:a] + "// %s: asic/pnr/mem_macros.v\n" % m + t[b:]
open(sys.argv[2], "w").write(t)
EOF
  bb=$(ls $M/*/*.bb.v | tr '\n' ' ')
  libopt=$(ls $M/*/*.lib | sed 's/^/-liberty /' | tr '\n' ' ')
  romv=""; [ "${ROM_MACRO:-0}" = 1 ] && romv="read_verilog -defer /mnt/g/AV2/asic/pnr/mem_macros_rom.v"
  sed -e "s/@VS@/$vs/" -e "s/@FIP@/$fip/" -e "s/@PCW@/${PCW:-0}/" -e "s/@LR@/${LR:-0}/" -e "s/@CH@/${CH:-0}/" \
      -e "s#@LIB@#$lib#g" -e "s/@DELAY@/2500/g" -e "s#@OUT@#$out#g" \
      -e "s#@MACROS_BB@#$bb#" -e "s#@MACROS_LIBOPT@#$libopt#" -e "s#^\# @ROMV@#$romv#" $P/synth_mac.ys > $out/synth.ys
  echo "synthesis $(date +%T)"
  (cd /mnt/g/AV2/rtl && nice -n 5 /opt/yosys/bin/yosys -q -l $out/yosys.log -s $out/synth.ys)
  grep -E "Chip area" $out/stat.txt | tail -1
  if grep -q "is used but has no driver" $out/yosys.log; then
    grep "is used but has no driver" $out/yosys.log | head -5; echo "ERROR: undriven wires"; exit 1
  fi
  grep -c "fakeram45_" $out/netlist.v | sed 's/^/macro lines in netlist: /'
fi
[ "${SYNTH_ONLY:-0}" = 1 ] && exit 0
echo "pnr $(date +%T)"
cd $out
NETLIST=$out/netlist.v OUT=$out SDC=$P/gdf_mac.sdc PERIOD=$period UTIL=$util THREADS=$thr MACRO_DIR=$M \
  nice -n 5 openroad -no_init -exit $P/pnr_mac.tcl > $out/pnr.log 2>&1 || { tail -30 $out/pnr.log; exit 1; }
grep -E "^STAGE|_WNS|CORE_AREA|Design area|PNR_DONE|MACRO" $out/pnr.log
