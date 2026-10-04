#!/usr/bin/env python3
"""Cut a small VCD out of a pin-level VCD: the header lines of the given
instance scopes and the value changes of their variables.
Usage: vcd_probe_small.py <pins.vcd> <out.vcd> <instance>..."""
import sys

src, dst, insts = sys.argv[1], sys.argv[2], set(sys.argv[3:])
out = open(dst, 'w')
keep = set()            # identifier codes of the variables of the instances
scope = []              # current scope path
with open(src) as f:
    # header: the two outermost scopes, the scopes of the instances with
    # their variables, and the lines outside any scope
    for line in f:
        t = line.split()
        if t and t[0] == '$scope':
            scope.append(t[2])
            if len(scope) <= 2 or t[2] in insts:
                out.write(line)
            continue
        if t and t[0] == '$upscope':
            s = scope.pop()
            if len(scope) <= 1 or s in insts:
                out.write(line)
            continue
        if t and t[0] == '$var':
            if scope and scope[-1] in insts:
                keep.add(t[3])
                out.write(line)
            continue
        if t and t[0] == '$enddefinitions':
            out.write(line)
            break
        if not scope:
            out.write(line)
    # body: every time stamp, and the scalar changes of the kept variables
    for line in f:
        c = line[0]
        if c == '#':
            out.write(line)
        elif c in '01xz' and line[1:].strip() in keep:
            out.write(line)
out.close()
print('vars kept', len(keep), sorted(keep))
