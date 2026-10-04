#!/usr/bin/env python3
"""Share of the cell instances of each function (labels of
layout_by_function.py) whose output pins are annotated in a pin-level VCD
(vcd_to_pins.py), read from the VCD header only.
Usage: vcd_coverage.py <labels.txt> <pins.vcd>"""
import collections
import sys

lab = {}
for line in open(sys.argv[1]):
    a, b = line.split()
    lab[a.replace('\\', '')] = b
seen = set()
with open(sys.argv[2]) as f:
    for line in f:
        t = line.split()
        if not t:
            continue
        if t[0] == '$scope' and len(t) > 2:
            seen.add(t[2].replace('\\', ''))
        elif t[0] == '$enddefinitions':
            break
tot = collections.Counter(lab.values())
hit = collections.Counter(v for k, v in lab.items() if k in seen)
for k in sorted(tot):
    print(f'{k:8s} {tot[k]:7d} instances, {hit[k]:7d} with annotated outputs ({100 * hit[k] / tot[k]:.1f}%)')
