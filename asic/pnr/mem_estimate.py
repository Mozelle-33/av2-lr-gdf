#!/usr/bin/env python3
"""First-order area and power of the memories of the joint LR/GDF stage from
the CACTI-based fakeram45 macro models of the OpenROAD flow (Nangate45
platform, 45 nm, 1.1 V).

For every fakeram45 macro: area (LEF SIZE), read energy (internal power of the
clock pin, fJ per access) and leakage.  Each memory of the stage is scaled per
bit from the macros of the nearest depth (4096-deep tables as two 2048-deep
banks), at the access rates of the streaming core (per cycle).  The four
dual-read error tables are counted as eight single-port copies.
Usage: mem_estimate.py [--ch]      (--ch: with the chroma LR column buffer)
"""
import glob
import math
import re
import sys

import numpy as np

PLAT = "/root/work/pnr/orfs/flow/platforms/nangate45"
F_HZ = 400e6

rows = []
for lib in sorted(glob.glob(PLAT + "/lib/fakeram45_*.lib")):
    m = re.search(r"fakeram45_(\d+)x(\d+)\.lib", lib)
    d, w = int(m.group(1)), int(m.group(2))
    t = open(lib).read()
    clk = t[t.index("pin(clk)"):]
    e = float(re.search(r"rise_power\(scalar\)\s*\{\s*values\s*\(\s*\"([0-9.]+)\"", clk).group(1))
    leak = [float(x) for x in re.findall(r"\bcell_leakage_power\s*:\s*([0-9.]+)", t)]
    lef = open(PLAT + f"/lef/fakeram45_{d}x{w}.lef").read()
    sx, sy = map(float, re.search(r"SIZE\s+([0-9.]+)\s+BY\s+([0-9.]+)", lef).groups())
    rows.append((d, w, sx * sy, e, max(leak) if leak else 0.0))

print("depth width area_um2 um2/bit read_fJ fJ/bit leak_nW nW/bit")
for d, w, a, e, lk in rows:
    print(f"{d:5d} {w:4d} {a:9.0f} {a/(d*w):6.3f} {e:8.1f} {e/w:6.1f} {lk:10.0f} {lk/(d*w):6.2f}")

DEPTHS = sorted({d for d, *_ in rows})


def f(key, depth):
    """Per-bit area (um2), energy per accessed bit (fJ) or leakage (nW), averaged
    over the macros of the nearest available depth; deeper memories are banks of
    the deepest macro (2048), one bank accessed per read."""
    dd = min(DEPTHS, key=lambda x: abs(math.log2(x) - math.log2(min(depth, DEPTHS[-1]))))
    sel = [r for r in rows if r[0] == dd]
    if key == "area":
        return float(np.mean([r[2] / (r[0] * r[1]) for r in sel]))
    if key == "energy":
        return float(np.mean([r[3] / r[1] for r in sel]))
    return float(np.mean([r[4] / (r[0] * r[1]) for r in sel]))


# memories of the joint stage: name, copies, depth, width, reads/cycle per copy,
# writes/cycle per copy (streaming, eight samples per cycle)
MEMS = [
    ("column buffer", 1, 34, 240, 1.0, 1.0),
    ("error tables (4 dual-read)", 8, 4096, 7, 1.0, 0.0),
    ("PC-Wiener class ROM", 1, 4096, 8, 0.5, 0.0),
    ("PC-Wiener Q tables", 4, 64, 26, 1.0, 0.0),
    ("LR selector ROM", 1, 1024, 6, 0.5, 0.0),
    ("LR coefficient banks", 1, 256, 105, 0.5, 0.0),
]
if "--ch" in sys.argv:        # chroma LR (CH = 1): strips c-2, c-1 and the carry
    MEMS.append(("chroma column buffer", 1, 34, 130, 1.0, 1.0))
tot_a = tot_dyn = tot_leak = tot_bits = 0.0
print("\nmemory copies depth width kb area_um2 dyn_mW leak_mW")
for name, n, d, w, rd, wr in MEMS:
    bits = n * d * w
    area = bits * f("area", d)
    dyn = n * (rd + wr) * w * f("energy", d) * 1e-15 * F_HZ * 1e3
    leak = bits * f("leak", d) * 1e-6
    tot_a += area; tot_dyn += dyn; tot_leak += leak; tot_bits += bits
    print(f"{name:28s} {n} {d:5d} {w:4d} {bits/1024:6.1f} {area:9.0f} {dyn:6.2f} {leak:6.2f}")
print(f"TOTAL {tot_bits/1024:.1f} kb stored, area {tot_a/1e6:.3f} mm2, "
      f"dynamic {tot_dyn:.1f} mW, leakage {tot_leak:.1f} mW at {F_HZ/1e6:.0f} MHz")
