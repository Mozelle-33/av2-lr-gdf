#!/usr/bin/env python3
"""Toggles of the clock-tree nets in a pin-level VCD (vcd_to_pins.py): the
output pins of the clock buffers (scopes clkbuf_*, clkload*) and how many of
them never toggle.  Usage: vcd_clock_check.py <pins.vcd>"""
import collections
import sys

ids = {}
scope = []
with open(sys.argv[1]) as f:
    for line in f:
        t = line.split()
        if not t:
            continue
        if t[0] == '$scope':
            scope.append(t[2])
        elif t[0] == '$upscope':
            scope.pop()
        elif t[0] == '$var':
            s = scope[-1] if scope else ''
            if s.startswith(('clkbuf', 'clkload')):
                ids[t[3]] = s
        elif t[0] == '$enddefinitions':
            break
    cnt = collections.Counter()
    for line in f:
        if line[0] in '01':
            k = line[1:].strip()
            if k in ids:
                cnt[k] += 1
zero = [ids[k] for k in ids if cnt[k] == 0]
print(f'clock-tree pins in the VCD: {len(ids)}, never toggling: {len(zero)}')
vals = sorted(cnt[k] for k in ids)
if vals:
    print(f'toggles min {vals[0]}, median {vals[len(vals) // 2]}, max {vals[-1]}')
print('examples of non-toggling:', zero[:8])
