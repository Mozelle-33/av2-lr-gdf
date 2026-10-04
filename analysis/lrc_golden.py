#!/usr/bin/env python3
"""Bit-exact golden model of the AV2 chroma loop restoration (cross-component
non-separable Wiener filter of AVM 1.0.0), checked against the AVM_LRC_DUMP
records of the instrumented decoder (analysis/lrc_dump.py):

  1. LRSL: the cross-component luma down-sampler (cfl_ds_filter_index 0: 2x2
     sum >> 2, 1: vertical pair sum >> 1, 2: decimation), and the assumption of
     the hardware that luma rows beyond the two saved rows of a stripe repeat
     the outermost one;
  2. LRSC: every chroma stripe of a restoration unit, from its own input, the
     down-sampled luma the filter reads and the signaled taps;
  3. the down-sampled luma of every LRSC record equals the LRSL output of its
     stripe, extended by replication at the picture edges (so that a decoder
     can compute it from the luma stream of the stripe).

Filter (wienerns_filter_uv, 7-bit precision): 6 symmetric chroma pairs and 12
asymmetric taps on the down-sampled luma, both relative to their center,
  y = clip(Round2Signed(128 x0 + sum_k c_k (u(+d_k) + u(-d_k) - 2 x0)
                                + sum_j d_j (l(p_j) - l0), 7)).
Usage: lrc_golden.py <dump.lrcdump>...
"""
import sys
from collections import defaultdict

import numpy as np

from lrc_dump import records

PREC = 7
UV_PAIRS = [(1, 0), (0, 1), (1, 1), (-1, 1), (2, 0), (0, 2)]      # taps 0..5
LUMA_TAPS = [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1), (-1, 1), (1, -1),
             (2, 0), (-2, 0), (0, 2), (0, -2)]                     # taps 6..17
RESTORE_NONE = 0


def round2signed(x, n):
    return np.where(x >= 0, (x + (1 << (n - 1))) >> n, -((-x + (1 << (n - 1))) >> n))


def downsample(src, ds_type, h_uv, w_uv):
    s = src.astype(np.int64)
    if ds_type == 1:
        return ((s[0:2 * h_uv:2, 0:2 * w_uv:2] + s[1:2 * h_uv:2, 0:2 * w_uv:2]) >> 1)
    if ds_type == 2:
        return s[0:2 * h_uv:2, 0:2 * w_uv:2]
    return ((s[0:2 * h_uv:2, 0:2 * w_uv:2] + s[0:2 * h_uv:2, 1:2 * w_uv:2]
             + s[1:2 * h_uv:2, 0:2 * w_uv:2] + s[1:2 * h_uv:2, 1:2 * w_uv:2]) >> 2)


def chroma_filter(dgd, bv, bh, luma, lb, taps, h, w, bit_depth):
    """Filtered stripe (h x w) from the stripe input with borders bv/bh and the
    down-sampled luma with border lb (int64 arrays)."""
    x = dgd.astype(np.int64)
    l = luma.astype(np.int64)
    x0 = x[bv:bv + h, bh:bh + w]
    l0 = l[lb:lb + h, lb:lb + w]
    acc = x0 << PREC
    for k, (dr, dc) in enumerate(UV_PAIRS):
        a = x[bv + dr:bv + dr + h, bh + dc:bh + dc + w]
        b = x[bv - dr:bv - dr + h, bh - dc:bh - dc + w]
        acc = acc + int(taps[k]) * (a + b - 2 * x0)
    for j, (dr, dc) in enumerate(LUMA_TAPS):
        p = l[lb + dr:lb + dr + h, lb + dc:lb + dc + w]
        acc = acc + int(taps[6 + j]) * (p - l0)
    y = round2signed(acc, PREC)
    return np.clip(y, 0, (1 << bit_depth) - 1)


def main(paths):
    tot = defaultdict(int)
    bad = defaultdict(int)
    for path in paths:
        # the LRSL records of a frame (stripe 0 first) precede its LRSC
        # records; order hints repeat (every frame of an all-intra stream is a
        # key frame), so records are matched in file order
        lrsl = {}                       # frame_stripe -> header, ds rows
        for kind, h, a in records(path):
            if kind == 'LRSL':
                tot['lrsl'] += 1
                huv, wuv = h['h_uv'], h['width_uv']
                ds = downsample(a['src'], h['ds_type'], huv, wuv)
                if not np.array_equal(ds, a['ds'].astype(np.int64)):
                    bad['lrsl'] += 1
                # rows beyond the saved rows repeat the outermost one:
                # src rows 0..3 = luma rows y0-4..y0-1 (above), and the last
                # four rows y1..y1+3 (below)
                src = a['src']
                if h['above']:
                    tot['rep_above'] += 1
                    if not (np.array_equal(src[0], src[2]) and np.array_equal(src[1], src[2])):
                        bad['rep_above'] += 1
                if h['below']:
                    tot['rep_below'] += 1
                    n = src.shape[0]
                    if not (np.array_equal(src[n - 1], src[n - 3]) and np.array_equal(src[n - 2], src[n - 3])):
                        bad['rep_below'] += 1
                if h['frame_stripe'] == 0:
                    lrsl = {}
                lrsl[h['frame_stripe']] = (h, a['ds'])
                continue
            tot['stripes'] += 1
            hh, w = h['height'], h['width']
            bd = h['bit_depth']
            if h['has_lossless_segment'] > 0 or h['num_classes'] != 1 or not h['has_luma']:
                tot['skipped'] += 1
                continue
            y = chroma_filter(a['dgd'], h['border_v'], h['border_h'], a['luma'],
                              h['luma_border'], a['taps'], hh, w, bd)
            # processing units with local_rest_type RESTORE_NONE are copied
            pw = h['procunit_width']
            x0 = a['dgd'][h['border_v']:h['border_v'] + hh, h['border_h']:h['border_h'] + w]
            for p, t in enumerate(a['pu_type']):
                if t == RESTORE_NONE:
                    y[:, p * pw:(p + 1) * pw] = x0[:, p * pw:(p + 1) * pw]
                    tot['pu_none'] += 1
            tot['samples'] += hh * w
            mism = int(np.count_nonzero(y != a['dst']))
            if mism:
                bad['stripes'] += 1
                bad['samples'] += mism
                if bad['stripes'] <= 5:
                    r, c = np.argwhere(y != a['dst'])[0]
                    print(f"{path}: plane {h['plane']} oh {h['order_hint']} at ({h['v_start']},{h['h_start']}) "
                          f"{hh}x{w}: {mism} mismatches, first ({r},{c}) {y[r, c]}/{a['dst'][r, c]}")
            # 3. the luma the filter reads = LRSL output of its stripe, edge-replicated
            lb = h['luma_border']
            row0 = h['v_start'] - lb
            # frame stripe of the chroma stripe: 64 >> ss_y rows, the first
            # one shorter by 8 >> ss_y
            fs = (h['v_start'] + (8 >> h['ss_y'])) // (64 >> h['ss_y'])
            if fs not in lrsl:
                tot['luma_unmatched'] += 1
                continue
            lh, ds = lrsl[fs]
            first = (lh['y0'] >> lh['ss_y']) - 2 * lh['above']
            # top/bottom of the picture: the down-sampler extends by replication
            rows = np.arange(row0, row0 + hh + 2 * lb) - first
            rows = np.clip(rows, 0, ds.shape[0] - 1)
            cols = np.clip(np.arange(h['h_start'] - lb, h['h_start'] + w + lb), 0, lh['width_uv'] - 1)
            exp_l = ds[np.ix_(rows, cols)]
            tot['luma_checked'] += 1
            if not np.array_equal(exp_l, a['luma']):
                bad['luma'] += 1
                if bad['luma'] <= 3:
                    rr, cc = np.argwhere(exp_l != a['luma'])[0]
                    print(f"{path}: luma of plane {h['plane']} stripe ({h['v_start']},{h['h_start']}) differs at "
                          f"({rr - lb},{cc - lb}): {exp_l[rr, cc]}/{a['luma'][rr, cc]}")
    print(f"LRSL {tot['lrsl']} down-sampler mismatches {bad['lrsl']}; "
          f"replicated rows above {tot['rep_above'] - bad['rep_above']}/{tot['rep_above']}, "
          f"below {tot['rep_below'] - bad['rep_below']}/{tot['rep_below']}")
    print(f"LRSC stripes {tot['stripes']} (skipped {tot['skipped']}, PUs off {tot['pu_none']}), "
          f"samples {tot['samples']}, mismatching stripes {bad['stripes']}, samples {bad['samples']}")
    print(f"luma of the filter = LRSL output: {tot['luma_checked'] - bad['luma']}/{tot['luma_checked']}, "
          f"unmatched {tot['luma_unmatched']}")
    return 0 if not any(bad.values()) else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
