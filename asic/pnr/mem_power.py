#!/usr/bin/env python3
"""Power of the SRAM macros of a routed gdf_core (pnr_mac.tcl) by memory, from
the per-instance OpenSTA report of power_vcd.tcl (INST_RPT): internal
(CACTI read and write energies on the clock edges of the accesses), switching
(none: the macro pins are loads of the logic) and leakage, with the macro
areas of final.def / the macro LEFs.
Usage: mem_power.py <run dir> <instance power report> <macro dir>
"""
import collections
import glob
import os
import re
import sys

run, rpt, mdir = sys.argv[1:4]
# memories of the stage and the instance names of their macros
GROUPS = [('Luma column buffer', r'\bu_cb\b'), ('Chroma column buffer', r'\bu_ccb\b'),
          ('GDF error tables', r'g_luts\.'), ('PC-Wiener Q tables', r'\bu_ql\b'),
          ('LR coefficient banks', r'\bu_lc\b'), ('PC-Wiener class ROM', r'\bu_pcr\b')]
# macro areas from the LEF views, macro instances from the routed DEF
size = {}
for lef in glob.glob(os.path.join(mdir, '*', '*.lef')):
    t = open(lef).read()
    m = re.search(r'MACRO\s+(\S+).*?SIZE\s+([\d.]+)\s+BY\s+([\d.]+)', t, re.S)
    size[m.group(1)] = float(m.group(2)) * float(m.group(3))
macros = {}
sect = False
for line in open(os.path.join(run, 'final.def')):
    if line.startswith('COMPONENTS'):
        sect = True
    elif line.startswith('END COMPONENTS'):
        break
    elif sect:
        m = re.match(r'\s*-\s+(\S+)\s+(fakeram45_\S+)', line)
        if m:
            macros[m.group(1).replace('\\', '')] = m.group(2)
# power per memory: report lines are "internal switching leakage total
# instance" (in watts); only the macro instances are summed
pw = collections.defaultdict(lambda: [0.0, 0.0, 0.0, 0.0])
area = collections.Counter()
count = collections.Counter()
found = 0
for line in open(rpt):
    t = line.split()
    if len(t) != 5:
        continue
    inst = t[4].replace('\\', '')
    if inst not in macros:
        continue
    vals = [float(x) for x in t[:4]]
    g = next((n for n, rx in GROUPS if re.search(rx, inst)), 'other')
    for k in range(4):
        pw[g][k] += vals[k]
    area[g] += size[macros[inst]]
    count[g] += 1
    found += 1
# table: macros, area and power of every memory, and the totals
print(f'macros in the report: {found} of {len(macros)}')
print(f'{"memory":24s} {"n":>2s} {"mm2":>7s} {"int mW":>8s} {"sw mW":>7s} {"leak mW":>8s} {"total mW":>9s}')
tot = [0.0] * 4
for g, _ in GROUPS + [('other', '')]:
    if g not in pw:
        continue
    v = pw[g]
    tot = [a + b for a, b in zip(tot, v)]
    print(f'{g:24s} {count[g]:2d} {area[g] / 1e6:7.4f} {v[0] * 1e3:8.2f} {v[1] * 1e3:7.2f} '
          f'{v[2] * 1e3:8.2f} {v[3] * 1e3:9.2f}')
print(f'{"total":24s} {sum(count.values()):2d} {sum(area.values()) / 1e6:7.4f} {tot[0] * 1e3:8.2f} '
      f'{tot[1] * 1e3:7.2f} {tot[2] * 1e3:8.2f} {tot[3] * 1e3:9.2f}')
