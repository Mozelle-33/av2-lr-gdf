#!/usr/bin/env python3
"""Toggles per function in a pin-level VCD (vcd_to_pins.py): the value changes
of the annotated output pins of the instances of each function (labels of
layout_by_function.py), per instance and cycle (2.5-ns cycles).
Usage: vcd_toggles.py <labels.txt> <pins.vcd>"""
import collections
import sys

lab = {}                # instance -> function
for line in open(sys.argv[1]):
    a, b = line.split()
    lab[a.replace('\\', '')] = b
idfun = {}              # identifier code of a pin -> function of its instance
scope = []
tend = 0                # last time stamp
with open(sys.argv[2]) as f:
    # header: a variable belongs to the instance that is its scope
    for line in f:
        t = line.split()
        if not t:
            continue
        if t[0] == '$scope':
            scope.append(t[2].replace('\\', ''))
        elif t[0] == '$upscope':
            scope.pop()
        elif t[0] == '$var':
            fn = lab.get(scope[-1]) if scope else None
            if fn:
                idfun[t[3]] = fn
        elif t[0] == '$enddefinitions':
            break
    # body: count the scalar value changes per function
    cnt = collections.Counter()
    for line in f:
        c = line[0]
        if c == '#':
            tend = int(line[1:])
        elif c in '01xz':
            fn = idfun.get(line[1:].strip())
            if fn:
                cnt[fn] += 1
ninst = collections.Counter(lab.values())
cycles = tend / 2500.0 if tend else 1
print(f'end time {tend}, {cycles:.0f} cycles of 2.5 ns (if ps)')
for k in sorted(cnt):
    print(f'{k:8s} toggles {cnt[k]:12d}  per instance and cycle {cnt[k] / ninst[k] / cycles:.4f}')
