#!/usr/bin/env python3
"""Power of the instances of one function (labels of layout_by_function.py)
by cell type, from the per-instance OpenSTA report and the DEF of a run.
Usage: power_by_celltype.py <run dir> <labels.txt> <instance report> <function>"""
import collections
import re
import sys

run, labp, rptp, fn = sys.argv[1:5]
# instances of the function (label lines are "instance function")
lab = {}
for line in open(labp):
    a, b = line.split()
    if b == fn:
        lab[a.replace('\\', '')] = b
# cell of every instance, from the COMPONENTS section of the routed DEF
cell = {}
sect = False
for line in open(run + '/final.def'):
    if line.startswith('COMPONENTS'):
        sect = True
    elif line.startswith('END COMPONENTS'):
        break
    elif sect:
        m = re.match(r'\s*-\s+(\S+)\s+(\S+)', line)
        if m:
            cell[m.group(1).replace('\\', '')] = m.group(2)
# cell type -> [instances, internal, switching, total power in watts]; report
# lines are "internal switching leakage total instance"
s = collections.defaultdict(lambda: [0, 0.0, 0.0, 0.0])
for line in open(rptp):
    t = line.split()
    if len(t) != 5:
        continue
    try:
        v = [float(x) for x in t[:4]]
    except ValueError:
        continue
    k = t[4].replace('\\', '')
    if k not in lab:
        continue
    c = re.sub(r'_X\d+$', '', cell.get(k, '?'))     # cell type without its drive strength
    s[c][0] += 1
    s[c][1] += v[0]
    s[c][2] += v[1]
    s[c][3] += v[3]
# the twelve cell types with the highest total power
print(f'{fn}: cell type, count, internal mW, switching mW, total mW')
for c, (n, i, w, tot) in sorted(s.items(), key=lambda kv: -kv[1][3])[:12]:
    print(f'  {c:10s} {n:7d} {i * 1e3:8.2f} {w * 1e3:8.2f} {tot * 1e3:8.2f}')
