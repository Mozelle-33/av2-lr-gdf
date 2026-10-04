#!/usr/bin/env python3
"""Placement of a routed run colored by function, and the cell area per function.

Yosys flattens the core, so instance names are anonymous, but many nets keep
their RTL names.  Every cell that drives a named net is assigned the function of
that name (regular expressions below); an anonymous cell takes the function of
the nearest assigned cell in its fan-out (breadth-first backwards through the
input pins), i.e., logic counts for the named signal it computes.  Clock-tree
cells form their own class.  The assignment of the anonymous logic is
approximate, which is why only area shares are reported.  SRAM macros
(fakeram45_*, from the further LEF files) are drawn as outlined blocks and
labeled 'mem'; their area is reported apart from the cell area.

Usage: layout_by_function.py <run dir with final.def> <lef[,macro.lef,...]> <out.png> [<out.csv>]
"""
import collections
import os
import re
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

FUNCS = [
    # (key, label, color, regex on the net name without escapes); first match wins
    ('lrc', 'Chroma LR', (227, 119, 194), r'^g_ch\.|^in_c_|^out_c_'),
    ('lr', 'LR filter (taps, products, tree)', (148, 103, 189),
     r'^g_col\.g_pcw\.g_lr\.|^ltk|^in_lr|^lron|^out_y'),
    ('lrcls', 'LR classifier', (23, 190, 207), r'^g_col\.g_pcw\.|^g_col\.g_vb\.lrs|^out_pcw'),
    ('mul', 'GDF products and trees', (214, 39, 40),
     r'^g_samp\[\d+\]\.genblk1\.g_prop\.g_m|^g_gm\b|^g_gm\[|^acc_|^g_samp\[\d+\]\.genblk1'),
    ('feat', 'GDF features (differences, clips)', (255, 127, 14),
     r'^diff_|^g_samp\[\d+\]\.(clip|feat)|^dsrc|^feat|^g_samp\['),
    ('quant', 'GDF quantizer, table port, compensation', (188, 189, 34),
     r'^g_quant|^g_luts|^err_|^cv_|^out_(err|corr)|^corr|^q[0-2]?_|^idx|^lut'),
    ('cls', 'Laplacians, cells, boxes, GDF class', (44, 160, 44),
     r'^g_col\.(g_vb|g_box|box|vlap|vlraw|g_lap|lo\b|lo\[|g_cls|cls|g_vh|g_c\b)|^box|^graw|^gs\d|^gsum|^cls|^grad'),
    ('win', 'Column buffer port, window', (31, 119, 180), r'^g_col\.|^in_data|^in_norm|^in_'),
    ('cfg', 'Configuration registers', (140, 86, 75), r'^wbus|^abus|^asel|^bias|^cfg|^mode|^tok|^w_|^a_'),
]
OTHER = ('other', 'Clock tree, control', (90, 90, 90))
MEM = ('mem', 'Memory macros', (253, 208, 162))
COMPILED = [(k, re.compile(rx)) for k, _, _, rx in FUNCS]


# function of a named net: the first pattern of FUNCS that matches
def classify(name):
    for k, rx in COMPILED:
        if rx.search(name):
            return k
    return None


# sizes and pin directions of the cells and macros of a LEF file
def read_lef(path):
    size = {}
    outputs, inputs = collections.defaultdict(set), collections.defaultdict(set)
    macro = pin = None
    for line in open(path):
        t = line.split()
        if not t:
            continue
        if t[0] == 'MACRO':
            macro = t[1]
        elif t[0] == 'SIZE' and macro:
            size[macro] = (float(t[1]), float(t[3]))
        elif t[0] == 'PIN' and macro:
            pin = t[1]
        elif t[0] == 'DIRECTION' and macro and pin:
            (outputs if t[1].startswith('OUTPUT') else inputs)[macro].add(pin)
        elif t[0] == 'END' and len(t) > 1 and t[1] == macro:
            macro = None
    return size, outputs, inputs


# placed components (master, x, y in database units), nets with their pins,
# database units per micron and the die box of a DEF file
def read_def(path):
    comps, nets = {}, []
    units, die = 2000, None
    sect = None
    buf = ''
    with open(path) as f:
        for line in f:
            if line.startswith('UNITS DISTANCE MICRONS'):
                units = int(line.split()[3])
            elif line.startswith('DIEAREA'):
                n = list(map(int, re.findall(r'-?\d+', line)))
                die = (n[0], n[1], n[2], n[3])
            elif line.startswith('COMPONENTS'):
                sect = 'C'
            elif line.startswith('END COMPONENTS'):
                sect = None
            elif line.startswith('NETS'):
                sect = 'N'
            elif line.startswith('END NETS'):
                break
            elif sect == 'C':
                m = re.match(r'\s*-\s+(\S+)\s+(\S+).*\+\s+(?:PLACED|FIXED)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)\s+(\S+)', line)
                if m:
                    comps[m.group(1)] = (m.group(2), int(m.group(3)), int(m.group(4)))
            elif sect == 'N':
                s = line.strip()
                if s.startswith('- '):
                    buf = s
                else:
                    buf += ' ' + s
                if s.endswith(';') or '+ ROUTED' in s or '+ USE' in s:
                    if buf.startswith('- '):
                        head = buf.split('+')[0]
                        name = head.split()[1]
                        pins = re.findall(r'\(\s*(\S+)\s+(\S+)\s*\)', head)
                        nets.append((name, pins))
                    buf = ''
    return comps, nets, units, die


def main():
    run, lef, png = sys.argv[1], sys.argv[2], sys.argv[3]
    csv = sys.argv[4] if len(sys.argv) > 4 else None
    size, outputs, inputs = {}, collections.defaultdict(set), collections.defaultdict(set)
    for lf in lef.split(','):
        s, o, i = read_lef(lf)
        size.update(s)
        for k, v in o.items():
            outputs[k] |= v
        for k, v in i.items():
            inputs[k] |= v
    comps, nets, units, die = read_def(f'{run}/final.def')
    label = {}
    macros = {inst for inst, (cell, _, _) in comps.items() if cell.startswith('fakeram45_')}
    for inst, (cell, _, _) in comps.items():
        if inst in macros:
            label[inst] = MEM[0]
        elif cell.startswith('CLKBUF') or inst.startswith(('clkbuf', 'clkload')):
            label[inst] = OTHER[0]
    in_nets = collections.defaultdict(list)     # cell -> drivers of its input nets
    for name, pins in nets:
        clean = name.replace('\\', '')
        drivers = [i for i, p in pins if i in comps and p in outputs.get(comps[i][0], ())]
        if not re.fullmatch(r'_\d+_(\[\d+\])?', clean) and not clean.startswith(('wire', 'net')):
            k = classify(clean)
            if k:
                for d in drivers:
                    label.setdefault(d, k)
        for i, p in pins:
            if i in comps and p in inputs.get(comps[i][0], ()):
                in_nets[i].extend(drivers)
    # backwards through the fan-in: logic belongs to the named signal it computes
    frontier = collections.deque(i for i in label if label[i] not in (OTHER[0], MEM[0]))
    while frontier:
        c = frontier.popleft()
        for d in in_nets.get(c, ()):
            if d not in label:
                label[d] = label[c]
                frontier.append(d)
    keys = [k for k, *_ in FUNCS] + [OTHER[0]]
    names = {k: l for k, l, *_ in FUNCS}
    names[OTHER[0]] = OTHER[1]
    colors = {k: c for k, _, c, _ in FUNCS}
    colors[OTHER[0]] = OTHER[2]
    area = collections.Counter()
    mem_area = 0.0
    W = 1600
    x0, y0, x1, y1 = die
    scale = W / (x1 - x0)
    H = int((y1 - y0) * scale)
    img = np.full((H, W, 3), 255, np.uint8)
    # the core area in the gray of unused sites: the keep-out halos around the
    # macros have no rows (and so no filler cells) and would otherwise show as
    # white frames, as if the macros covered cells (no cell lies under a macro
    # or in its halo)
    ext = [(x, y, x + size.get(c, (0.0, 0.0))[0] * units, y + size.get(c, (0.0, 0.0))[1] * units)
           for c, x, y in comps.values()]
    cx0, cy0 = min(e[0] for e in ext), min(e[1] for e in ext)
    cx1, cy1 = max(e[2] for e in ext), max(e[3] for e in ext)
    img[max(H - int((cy1 - y0) * scale), 0):H - int((cy0 - y0) * scale),
        int((cx0 - x0) * scale):int((cx1 - x0) * scale)] = (232, 232, 232)
    boxes = []
    for inst, (cell, x, y) in comps.items():
        w, h = size.get(cell, (0.0, 0.0))
        if inst in macros:
            mem_area += w * h
            boxes.append((int((x - x0) * scale), H - int((y + h * units - y0) * scale),
                          int((x + w * units - x0) * scale), H - int((y - y0) * scale)))
            continue
        if cell.startswith(('FILLCELL', 'TAPCELL')):
            col = (232, 232, 232)
        else:
            k = label.get(inst, OTHER[0])
            area[k] += w * h
            col = colors[k]
        px0 = int((x - x0) * scale)
        py1 = H - int((y - y0) * scale)
        px1 = max(px0 + 1, int((x + w * units - x0) * scale))
        py0 = min(py1 - 1, H - int((y + h * units - y0) * scale))
        img[max(py0, 0):max(py1, 0), max(px0, 0):px1] = col
    tot = sum(area.values())
    im = Image.fromarray(img)
    dm = ImageDraw.Draw(im)
    for bx in boxes:                         # macros: filled, outlined
        dm.rectangle(bx, fill=MEM[2], outline=(60, 60, 60), width=2)
    if os.environ.get('NOLEGEND') == '1':      # legend drawn by the paper (TikZ)
        im.save(png)
    # legend strip below the layout
    leg_h = 26 * ((len(keys) + 1) // 2) + 10
    out = Image.new('RGB', (W, H + leg_h), (255, 255, 255))
    out.paste(im, (0, 0))
    d = ImageDraw.Draw(out)
    try:
        font = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf', 18)
    except OSError:
        font = ImageFont.load_default()
    for n, k in enumerate(keys):
        cx = 10 + (n % 2) * (W // 2)
        cy = H + 8 + 26 * (n // 2)
        d.rectangle([cx, cy, cx + 18, cy + 18], fill=colors[k])
        d.text((cx + 26, cy), f'{names[k]}: {100 * area[k] / tot:.1f}%', fill=(0, 0, 0), font=font)
    if os.environ.get('NOLEGEND') != '1':
        out.save(png)
    print(f'die {(x1 - x0) / units:.0f} x {(y1 - y0) / units:.0f} um, cells {len(comps)}, '
          f'assigned {len(label)}, cell area {tot:.0f} um2, macros {len(macros)} {mem_area:.0f} um2')
    for k in keys:
        print(f'{names[k]:40s} {area[k]:10.0f} um2 {100 * area[k] / tot:5.1f}% {area[k] / 0.798:8.0f} GE')
    if csv:
        with open(csv, 'w') as f:
            f.write('function,area_um2,share,kGE\n')
            for k in keys:
                f.write(f'{names[k]},{area[k]:.0f},{area[k] / tot:.4f},{area[k] / 0.798 / 1000:.1f}\n')
            if macros:
                f.write(f'{MEM[1]},{mem_area:.0f},,\n')
    if os.environ.get('LABELS'):              # instance -> function (power_by_function.py)
        with open(os.environ['LABELS'], 'w') as f:
            for inst, (cell, _, _) in comps.items():
                if not cell.startswith(('FILLCELL', 'TAPCELL')):
                    f.write(f'{inst} {label.get(inst, OTHER[0])}\n')


if __name__ == '__main__':
    main()
