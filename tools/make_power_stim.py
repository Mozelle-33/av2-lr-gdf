#!/usr/bin/env python3
"""Stimulus for the SAIF power simulation of gdf_core (fpga/power/tb_power.v).

Takes the configuration of one table set and its real-content segments (no
stress units) from a self-test ROM directory (tools/make_rom.py) and writes:
  ops.hex  one 32-bit op per line:
             1 | addr[29:17] | data[15:0]          configuration write
             2 | H[29:23] | NCH[22:12] | LASTV     segment, followed by the CRC
             0                                     marker: start of the
                                                   measured window (after the
                                                   first table-set load)
             3                                     end
  in.hex   the input words of the chosen segments, in order (80 bit)
Usage: make_power_stim.py <romdir> <outdir> [set_a set_b]
"""
import json
import sys
from pathlib import Path

rom, out = Path(sys.argv[1]), Path(sys.argv[2])
want = [int(x) for x in sys.argv[3:5]] if len(sys.argv) >= 5 else [0, 1]
out.mkdir(parents=True, exist_ok=True)
man = json.loads((rom / "manifest.json").read_text())["segments"]
cmd = [int(x, 16) for x in (rom / "cmd.hex").read_text().split()]
inw = (rom / "in.hex").read_text().split()

ops, words, seg_i, i = [], [], 0, 0
cfg_done = False          # the chosen set's table load has been emitted
cur_set_cfg = []          # configuration writes seen since the last segment
while i < len(cmd):
    c = cmd[i]
    t = c >> 30
    if t == 1:
        cur_set_cfg.append(c)
        i += 1
    elif t == 2:
        seg = man[seg_i]
        crc = cmd[i + 1]
        keep = seg["set"] == want and seg["kind"] != "stress"
        if keep:
            if not cfg_done:
                ops += cur_set_cfg[:-1]      # table set (without the mode write)
                ops.append(0)                # marker: measured window starts
                ops.append(cur_set_cfg[-1])  # mode write of this segment
                cfg_done = True
            else:
                ops += [x for x in cur_set_cfg if ((x >> 17) & 0x1FFF) == 0x1C00]
            ops += [c, crc]
            words += inw[seg["in_base"]:seg["in_base"] + seg["words"]]
        cur_set_cfg = []
        seg_i += 1
        i += 2
    else:
        break
ops.append(3 << 30)
(out / "ops.hex").write_text("".join(f"{x:08x}\n" for x in ops))
(out / "in.hex").write_text("".join(w + "\n" for w in words))
kept = [s for s in man if s["set"] == want and s["kind"] != "stress"]
print(f"set {want}: {len(kept)} segments, {sum(s['h'] * s['w'] for s in kept)} samples, "
      f"{len(words)} input words, {len(ops)} ops")
