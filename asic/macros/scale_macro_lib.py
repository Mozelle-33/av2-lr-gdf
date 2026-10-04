#!/usr/bin/env python3
"""Corner versions of a macro Liberty model (gen_gdf_macros.py): the CACTI
timing exists for the typical corner only, so the clock-to-output delay, the
output transitions, the setup and hold constraints and the minimum period are
scaled by the median delay ratio of the Nangate45 cells between the corners
(asic/lib_corners; DFF, NAND2, INV, BUF, FA, AOI21, XOR2, MUX2: slow/typical
3.43, fast/typical 0.58).  Power, capacitance and table indices are kept.
Usage: scale_macro_lib.py <in.lib> <out.lib> <factor> <suffix>
"""
import re
import sys

src, dst, k, suffix = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
t = open(src).read()
GROUPS = r'(cell_rise|cell_fall|rise_transition|fall_transition|rise_constraint|fall_constraint)'
out, pos, n = [], 0, 0
for m in re.finditer(GROUPS + r'\s*\([^)]*\)\s*\{', t):
    v = t.index('values', m.end())
    e = t.index(')', t.index('(', v))
    out.append(t[pos:v])
    out.append(re.sub(r'\d+\.\d+', lambda x: '%.4f' % (float(x.group()) * k), t[v:e]))
    pos = e
    n += 1
out.append(t[pos:])
t = ''.join(out)
t = re.sub(r'(min_period\s*:\s*)(\d+\.\d+)', lambda x: '%s%.4f' % (x.group(1), float(x.group(2)) * k), t)
t = re.sub(r'^library\((\w+)\)', lambda x: 'library(%s_%s)' % (x.group(1), suffix), t, count=1, flags=re.M)
open(dst, 'w', newline='\n').write(t)
print(f'{src} -> {dst}: {n} tables scaled by {k}')
