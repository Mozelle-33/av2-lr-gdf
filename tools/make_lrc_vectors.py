#!/usr/bin/env python3
"""Test vectors of the chroma LR (gdf_lrc in gdf_core, CH = 1) from the chroma
LR dump of the instrumented decoder (AVM_LRC_DUMP, analysis/lrc_dump.py).

One segment per chroma LR stripe of a restoration unit (both planes when both
have LR there; a plane without a record is fed the other plane's samples with
LR off and is not checked).  The luma words of the segment are the luma rows
-2..H+1 that the cross-component down-sampler of the decoder reads (LRSL
records, columns -6..W+5 replicated at the picture edges), the chroma words
the stripe input of the record (rows -2..H/2+1, columns -4..W_c+1).

Records (tb/tb_gdf.cpp), after the "GDFV" header:
  type 1  configuration writes: u32 n, n x (u16 addr, u16 data)
  type 6  chroma segment: u16 H, u16 W, u16 NCH, u32 id, u16 W_c, u8 check
          (bit 0 U, bit 1 V), then
          u16 luma[(H/2+2) * NCH * 8]      words of row pairs, 2x4 per chunk
          u16 chroma[2][H/2+4][2*NCH]      rows -2..H/2+1, columns -4..
          u8  side[NCH]                    {V on, V bank, U on, U bank}
          u16 expected[2][H/2][W_c]
With --multi MAXW, a segment spans two or more adjacent restoration units of a
chroma stripe row (both planes, at most MAXW chroma columns); the up to four
filters of each plane sit in banks 0..3, and the side stream selects the bank
of the unit of every strip.
Usage: make_lrc_vectors.py <out.vec> <dump.lrcdump>... [--max N] [--multi MAXW]
"""
import struct
import sys
from collections import OrderedDict

import numpy as np

sys.path.insert(0, __file__.rsplit('/', 2)[0] + '/analysis')
from lrc_dump import records  # noqa: E402

RESTORE_NONE = 0


def segments(path):
    """Yield (luma LRSL header, src, {plane: (header, arrays)}) per RU stripe."""
    # the LRSL records of a frame (one per luma stripe) precede its LRSC records
    lrsl = {}
    groups = OrderedDict()
    frame = -1
    for kind, h, a in records(path):
        if kind == 'LRSL':
            if h['frame_stripe'] == 0:
                for g in groups.values():
                    yield g
                groups = OrderedDict()
                lrsl = {}
                frame += 1
            lrsl[h['frame_stripe']] = (h, a['src'])
            continue
        if h['num_classes'] != 1 or h['has_lossless_segment'] > 0 or not h['has_luma']:
            continue
        fs = (h['v_start'] + (8 >> h['ss_y'])) // (64 >> h['ss_y'])
        key = (frame, h['v_start'], h['h_start'], h['width'], h['height'])
        g = groups.setdefault(key, [lrsl.get(fs), {}])
        g[1][h['plane']] = (h, a)
    for g in groups.values():
        yield g


def build(lsl, planes, sid):
    any_h, _ = next(iter(planes.values()))
    hh, wc = any_h['height'], any_h['width']
    if hh % 2 or hh > 32 or wc % 2 or lsl is None:
        return None
    # luma words of the segment: 2x4 samples per strip and row pair
    lh, src = lsl
    H, W = 2 * hh, 2 * wc
    nch = (W + 12) // 4
    v0, h0 = any_h['v_start'], any_h['h_start']
    # luma rows -2..H+1 of the stripe (src starts at y0 - 4 * above)
    rows = np.clip(np.arange(-2, H + 2) + 4 * lh['above'], 0, src.shape[0] - 1)
    cols = np.clip(2 * h0 + np.arange(-6, 4 * nch - 6), 0, src.shape[1] - 1)
    lum = src[np.ix_(rows, cols)].astype(np.uint16)       # (H+4) x 4NCH
    words = np.zeros(((H + 4) // 2, nch, 8), np.uint16)
    for p in range((H + 4) // 2):
        for c in range(nch):
            words[p, c, 0:4] = lum[2 * p, 4 * c:4 * c + 4]
            words[p, c, 4:8] = lum[2 * p + 1, 4 * c:4 * c + 4]
    # chroma rows -2..hh+1, columns -4..2NCH-5 (dgd has border 2)
    chroma = np.zeros((2, hh + 4, 2 * nch), np.uint16)
    exp = np.zeros((2, hh, wc), np.uint16)
    side = np.zeros(nch, np.uint8)
    check = 0
    present = sorted(planes)
    for f in (0, 1):
        pl = 1 + f
        h, a = planes[pl] if pl in planes else planes[present[0]]
        bv, bh = h['border_v'], h['border_h']
        d = a['dgd'][bv - 2:bv + hh + 2, :]
        ccols = np.clip(np.arange(-4, 2 * nch - 4) + bh, 0, d.shape[1] - 1)
        chroma[f] = d[:, ccols]
        if pl in planes:
            check |= 1 << f
            exp[f] = a['dst']
            pw = h['procunit_width']
            for c in range(nch):
                x = 2 * c - 4
                if 0 <= x < wc and a['pu_type'][x // pw] != RESTORE_NONE:
                    side[c] |= 4 << (3 * f)                  # on, bank 0
    # configuration: mode, chroma flags (on, down-sampling filter, picture edges), taps of bank 0
    cfg = []
    bd10 = any_h['bit_depth'] == 10
    cfg.append((0x1C00, 2 if bd10 else 0))                   # luma: GDF, LR off
    top = v0 == 0
    bot = v0 + hh == any_h['frame_h']
    left = h0 == 0
    right = h0 + wc == any_h['frame_w']
    ds = any_h['ds_type'] if any_h['ds_type'] in (0, 1, 2) else 0
    cfg.append((0x1C02, 1 | (ds << 1) | (top << 3) | (bot << 4) | (left << 5) | (right << 6)))
    for f in (0, 1):
        if (1 + f) in planes:
            taps = planes[1 + f][1]['taps']
            for k in range(18):
                cfg.append((0x1D00 + (f << 7) + k, int(taps[k]) & 0xFFFF))
    rec = bytearray()
    rec += struct.pack('<BI', 1, len(cfg))
    for adr, val in cfg:
        rec += struct.pack('<HH', adr, val)
    rec += struct.pack('<BHHHIHB', 6, H, W, nch, sid, wc, check)
    rec += words.tobytes() + chroma.tobytes() + side.tobytes() + exp.tobytes()
    return rec, hh * wc * bin(check).count('1')


def frames(path):
    """Yield the RU stripe groups of every frame as (key, LRSL, {plane: (header,
    arrays)}), key = (v_start, h_start, width, height) in chroma samples."""
    lrsl = {}
    groups = OrderedDict()
    for kind, h, a in records(path):
        if kind == 'LRSL':
            if h['frame_stripe'] == 0:
                if groups:
                    yield list(groups.values())
                groups = OrderedDict()
                lrsl = {}
            lrsl[h['frame_stripe']] = (h, a['src'])
            continue
        if h['num_classes'] != 1 or h['has_lossless_segment'] > 0 or not h['has_luma']:
            continue
        fs = (h['v_start'] + (8 >> h['ss_y'])) // (64 >> h['ss_y'])
        key = (h['v_start'], h['h_start'], h['width'], h['height'])
        g = groups.setdefault(key, [key, lrsl.get(fs), {}])
        g[2][h['plane']] = (h, a)
    if groups:
        yield list(groups.values())


def taps_of(planes, p):
    return tuple(int(t) for t in planes[p][1]['taps'][:18])


def multi_segments(path, max_wc):
    """Segments of two or more adjacent restoration units of one chroma stripe
    row with both planes, each plane using up to four filters (banks 0..3 in
    order of appearance); a fifth filter or the width limit starts a new
    segment."""
    for groups in frames(path):
        rows = {}
        for key, lsl, planes in groups:
            if set(planes) == {1, 2} and lsl is not None:
                rows.setdefault((key[0], key[3]), []).append((key[1], key[2], lsl, planes))
        for _, lst in sorted(rows.items()):
            lst.sort(key=lambda t: t[0])
            seg, banks = [], {1: [], 2: []}
            for item in lst + [None]:
                new = {p: taps_of(item[3], p) for p in (1, 2)} if item else None
                cont = (item is not None and seg and item[0] == seg[-1][0] + seg[-1][1]
                        and sum(s[1] for s in seg) + item[1] <= max_wc
                        and all(new[p] in banks[p] or len(banks[p]) < 4 for p in (1, 2)))
                if not cont:
                    if len(seg) >= 2:
                        yield seg, banks
                    seg, banks = [], {1: [], 2: []}
                    if item is None:
                        continue
                seg.append(item)
                for p in (1, 2):
                    if new[p] not in banks[p]:
                        banks[p].append(new[p])


def build_multi(seg, banks, sid):
    """One chroma segment over the restoration units of seg; the side stream
    selects the bank of the unit of every strip."""
    h0, lsl = seg[0][0], seg[0][2]
    any_h = seg[0][3][1][0]
    hh = any_h['height']
    wc = sum(s[1] for s in seg)
    if hh % 2 or hh > 32 or wc % 2:
        return None
    lh, src = lsl
    H, W = 2 * hh, 2 * wc
    nch = (W + 12) // 4
    v0 = any_h['v_start']
    rows = np.clip(np.arange(-2, H + 2) + 4 * lh['above'], 0, src.shape[0] - 1)
    cols = np.clip(2 * h0 + np.arange(-6, 4 * nch - 6), 0, src.shape[1] - 1)
    lum = src[np.ix_(rows, cols)].astype(np.uint16)
    words = np.zeros(((H + 4) // 2, nch, 8), np.uint16)
    for p in range((H + 4) // 2):
        for c in range(nch):
            words[p, c, 0:4] = lum[2 * p, 4 * c:4 * c + 4]
            words[p, c, 4:8] = lum[2 * p + 1, 4 * c:4 * c + 4]

    # restoration unit of chroma column x (clamped to the first and last unit)
    def unit_of(x):
        for k, s in enumerate(seg):
            if s[0] <= x < s[0] + s[1]:
                return k
        return 0 if x < h0 else len(seg) - 1

    chroma = np.zeros((2, hh + 4, 2 * nch), np.uint16)
    exp = np.zeros((2, hh, wc), np.uint16)
    side = np.zeros(nch, np.uint8)
    for f in (0, 1):
        pl = 1 + f
        dgds = []
        for s in seg:
            h, a = s[3][pl]
            bv, bh = h['border_v'], h['border_h']
            dgds.append((a['dgd'][bv - 2:bv + hh + 2, :], bh))
        # the units' borders must agree with their neighbours' samples
        for k in range(len(seg) - 1):
            (d0, b0), (d1, b1) = dgds[k], dgds[k + 1]
            w0 = seg[k][1]
            n = min(b0, b1)
            if not ((d0[:, b0 + w0:b0 + w0 + n] == d1[:, b1:b1 + n]).all() and
                    (d1[:, b1 - n:b1] == d0[:, b0 + w0 - n:b0 + w0]).all()):
                return None
        for i, x in enumerate(range(h0 - 4, h0 + 2 * nch - 4)):
            k = unit_of(x)
            d, bh = dgds[k]
            chroma[f, :, i] = d[:, min(max(x - seg[k][0] + bh, 0), d.shape[1] - 1)]
        exp[f] = np.concatenate([s[3][pl][1]['dst'] for s in seg], axis=1)
        for c in range(nch):
            x = h0 + 2 * c - 4
            if h0 <= x < h0 + wc:
                k = unit_of(x)
                h, a = seg[k][3][pl]
                if a['pu_type'][(x - seg[k][0]) // h['procunit_width']] != RESTORE_NONE:
                    side[c] |= (4 | banks[pl].index(taps_of(seg[k][3], pl))) << (3 * f)
    cfg = []
    bd10 = any_h['bit_depth'] == 10
    cfg.append((0x1C00, 2 if bd10 else 0))
    top = v0 == 0
    bot = v0 + hh == any_h['frame_h']
    left = h0 == 0
    right = h0 + wc == any_h['frame_w']
    ds = any_h['ds_type'] if any_h['ds_type'] in (0, 1, 2) else 0
    cfg.append((0x1C02, 1 | (ds << 1) | (top << 3) | (bot << 4) | (left << 5) | (right << 6)))
    for f in (0, 1):
        for b, taps in enumerate(banks[1 + f]):
            for k in range(18):
                cfg.append((0x1D00 + (f << 7) + (b << 5) + k, taps[k] & 0xFFFF))
    rec = bytearray()
    rec += struct.pack('<BI', 1, len(cfg))
    for adr, val in cfg:
        rec += struct.pack('<HH', adr, val)
    rec += struct.pack('<BHHHIHB', 6, H, W, nch, sid, wc, 3)
    rec += words.tobytes() + chroma.tobytes() + side.tobytes() + exp.tobytes()
    return rec, 2 * hh * wc


def main_multi(out, dumps, max_wc):
    buf = bytearray(b'GDFV' + struct.pack('<I', 1))
    n = smp = skipped = units = 0
    nb = {1: 0, 2: 0, 3: 0, 4: 0}
    for path in dumps:
        for seg, banks in multi_segments(path, max_wc):
            r = build_multi(seg, banks, n)
            if r is None:
                skipped += 1
                continue
            buf += r[0]
            n += 1
            smp += r[1]
            units += len(seg)
            nb[max(len(banks[1]), len(banks[2]))] += 1
    buf += b'\x00'
    open(out, 'wb').write(buf)
    print(f'wrote {out}: {n} chroma segments over {units} restoration units, '
          f'banks per plane (max) {nb}, {smp} chroma samples checked, {skipped} skipped')


def main():
    args = sys.argv[1:]
    mx = None
    if '--max' in args:
        i = args.index('--max')
        mx = int(args[i + 1])
        del args[i:i + 2]
    if '--multi' in args:
        i = args.index('--multi')
        max_wc = int(args[i + 1])
        del args[i:i + 2]
        main_multi(args[0], args[1:], max_wc)
        return
    out, dumps = args[0], args[1:]
    buf = bytearray(b'GDFV' + struct.pack('<I', 1))
    n = smp = skipped = 0
    for path in dumps:
        for lsl, planes in segments(path):
            r = build(lsl, planes, n)
            if r is None:
                skipped += 1
                continue
            buf += r[0]
            n += 1
            smp += r[1]
            if mx and n >= mx:
                break
        if mx and n >= mx:
            break
    buf += b'\x00'
    open(out, 'wb').write(buf)
    print(f'wrote {out}: {n} chroma segments, {smp} chroma samples checked, {skipped} skipped')


if __name__ == '__main__':
    main()
