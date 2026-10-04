#!/usr/bin/env python3
"""Segment splits of full-width stripes and their cycle cost relative to
unsplit segments (paper, Section V-E).

GDF: the splits that the GDF block flags would need without the side stream
in_gdf (kept for reference: the stage now takes the flag per group, so these
splits are gone).  The dump holds the GDF units (64 columns) that GDF
filters; every change between filtered and unfiltered units of a stripe row
would split the row.
Chroma LR: four filter banks per plane are written between segments and the
side stream selects one per processing unit; a row splits where a plane needs
a fifth filter (greedy, left to right).
Cost model: a segment of width w and height h takes (h/2+2) * ceil((w+12)/4)
cycles plus a per-segment overhead of 24 cycles: real_all.vec, 24,396
segments, takes 15,390,684 segment cycles for 14,829,576 input cycles (23
cycles of drain per segment), plus one mode write.

Usage (WSL): python3 analysis/split_cost.py
"""
import glob
import math
import os
import sys
from collections import defaultdict

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gdf_dump import HDR_FIELDS  # noqa: E402
from lrc_dump import records as lrc_records  # noqa: E402

OVH = 24
W = '/root/work'


def gdf_headers(path):
    """Header fields of every unit, without the sample arrays."""
    data = np.fromfile(path, dtype=np.uint8)
    off = 0
    while off < len(data):
        assert bytes(data[off:off + 4]) == b'GDFU'
        rec = dict(zip(HDR_FIELDS, (int(v) for v in data[off + 4:off + 68].view('<i4'))))
        h = rec['i_max'] - rec['i_min']
        w = rec['j_max'] - rec['j_min']
        a = rec['apron']
        off += 68 + 2 * (h + 2 * a) * (w + 2 * a) + 3 * 2 * h * w
        yield rec


def seg_cycles(w, h):
    return (h // 2 + 2) * math.ceil((w + 12) / 4) + OVH


def row_cost(width, h, edges):
    """Extra cycles of a row split at the given columns, and its full cost."""
    segs = [b - a for a, b in zip([0] + edges, edges + [width])]
    full = seg_cycles(width, h)
    return sum(seg_cycles(w, h) for w in segs) - full, full


def gdf_stats(path):
    rows = defaultdict(list)
    fw = None
    for r in gdf_headers(path):
        rows[(r['frame_idx'], r['i_min'])].append((r['j_min'], r['j_max'], r['i_max'] - r['i_min']))
        fw = r['frame_w']
    st = defaultdict(float)
    for units in rows.values():
        units.sort()
        cov = []                                   # merged filtered intervals
        for a, b, _ in units:
            if cov and cov[-1][1] == a:
                cov[-1][1] = b
            else:
                cov.append([a, b])
        edges = sorted({x for iv in cov for x in iv} - {0, fw})
        extra, full = row_cost(fw, units[0][2], edges)
        st['rows'] += 1
        st['split_rows'] += bool(edges)
        st['splits'] += len(edges)
        st['full'] += full
        st['extra'] += extra
    return st


def lrc_stats(path):
    rus = defaultdict(dict)
    fw = None
    for kind, hd, arr in lrc_records(path):
        if kind != 'LRSC':
            continue
        rus[(hd['order_hint'], hd['v_start'])][(hd['h_start'], hd['plane'])] = (
            hd['height'], tuple(arr['taps'][:18].tolist()))
        fw = hd['frame_w']                         # chroma width
    st = defaultdict(float)
    for d in rus.values():
        banks = {1: set(), 2: set()}
        edges = []
        for x in sorted({x for x, _ in d}):
            need = {p: d[(x, p)][1] for p in (1, 2) if (x, p) in d}
            if any(f not in banks[p] and len(banks[p]) == 4 for p, f in need.items()):
                edges.append(2 * x)                # luma column of the split
                banks = {1: set(), 2: set()}
            for p, f in need.items():
                banks[p].add(f)
        extra, full = row_cost(2 * fw, 2 * max(v[0] for v in d.values()), edges)
        st['rows'] += 1
        st['split_rows'] += bool(edges)
        st['splits'] += len(edges)
        st['full'] += full
        st['extra'] += extra
    return st


def report(title, files, stats):
    tot = {'small': defaultdict(float), '4k': defaultdict(float)}
    print(title)
    for p in files:
        st = stats(p)
        k = '4k' if '3840x2160' in p else 'small'
        for key, v in st.items():
            tot[k][key] += v
        if st['rows']:
            print('  %-60s rows %4d, split %3d, splits %3d, +%.2f%%' % (
                os.path.basename(p)[:60], st['rows'], st['split_rows'], st['splits'],
                100 * st['extra'] / st['full']))
    for k, st in tot.items():
        if st['rows']:
            print('  %s: rows %d, split rows %d, splits %d, extra cycles %.2f%%' % (
                k, st['rows'], st['split_rows'], st['splits'], 100 * st['extra'] / st['full']))


report('GDF block flags (rows of frames with GDF):',
       sorted(glob.glob(W + '/dumps_lr/*.gdfdump') + glob.glob(W + '/dumps/*.gdfdump') +
              glob.glob(W + '/dumps_4k/*.gdfdump')), gdf_stats)
report('Chroma filters (four banks per plane):', sorted(glob.glob(W + '/dumps_lrc/*.lrcdump')), lrc_stats)
extra, full = row_cost(3840, 64, [1920])
print('one split of a 4K stripe (h = 64): %d cycles, %.2f%% of %d' % (extra, 100 * extra / full, full))
