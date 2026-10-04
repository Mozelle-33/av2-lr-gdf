#!/usr/bin/env python3
"""Logic power of a routed gdf_core by function: joins the per-instance power
of OpenSTA (power_vcd.tcl with INST_RPT) with the function labels of
layout_by_function.py (LABELS).  Clock-tree buffers are a function of their
own; the clock power of the flip-flops (internal power) stays with them.

Usage: power_by_function.py <instance power report> <labels> [out.csv]
"""
import collections
import sys

NAMES = {
    'lrc': 'Chroma LR', 'lr': 'Luma LR filter', 'lrcls': 'Luma LR classifier',
    'mul': 'GDF products and trees', 'feat': 'GDF features', 'quant': 'GDF index, table port, correction',
    'cls': 'Laplacians, cells, boxes, GDF class', 'win': 'Column buffer port, window',
    'cfg': 'Configuration registers', 'other': 'Clock tree, control', 'mem': 'Memory macros',
}


def main():
    rpt, lab = sys.argv[1], sys.argv[2]
    out = sys.argv[3] if len(sys.argv) > 3 else None
    label = {}
    for line in open(lab):
        inst, k = line.split()
        label[inst] = k
    power = collections.Counter()
    n = 0
    for line in open(rpt):
        t = line.split()
        # rows: internal switching leakage total instance
        if len(t) == 5:
            try:
                vals = [float(x) for x in t[:4]]
            except ValueError:
                continue
            inst = t[4].replace('\\', '')
            # labels keep the DEF escapes of brackets (\[ \]), the report not
            esc = t[4].replace('[', '\\[').replace(']', '\\]')
            power[label.get(inst, label.get(t[4], label.get(esc, 'other')))] += vals[3]
            n += 1
    tot = sum(power.values())
    print(f'instances {n}, total {tot * 1e3:.1f} mW')
    rows = sorted(power.items(), key=lambda kv: -kv[1])
    for k, p in rows:
        print(f'{NAMES.get(k, k):40s} {p * 1e3:8.1f} mW {100 * p / tot:5.1f}%')
    if out:
        with open(out, 'w') as f:
            f.write('function,mW,share\n')
            for k, p in rows:
                f.write(f'{NAMES.get(k, k)},{p * 1e3:.2f},{p / tot:.4f}\n')


if __name__ == '__main__':
    main()
