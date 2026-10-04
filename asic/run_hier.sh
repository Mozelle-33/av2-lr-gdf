#!/usr/bin/env bash
cd /root/work/asic
for f in 0 1; do
  out=/root/work/asic/hier_full$f; mkdir -p $out
  sed -e "s/@FULL@/$f/" -e "s#@OUT@#$out#" /mnt/g/AV2/asic/synth_hier.ys > $out/synth.ys
  /opt/yosys/bin/yosys -q -l $out/yosys.log -s $out/synth.ys &
done
wait
for f in 0 1; do echo "== FULL=$f"; grep -E "^=== |Chip area|gdf_mul|Number of cells" /root/work/asic/hier_full$f/stat_hier.txt | head -40; done
