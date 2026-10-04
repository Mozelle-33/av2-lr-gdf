#!/usr/bin/env python3
"""Reader for the chroma LR dump of the instrumented AVM decoder (AVM_LRC_DUMP,
see avm/av2/common/tcas_instr.h): LRSC records (one per chroma LR stripe of a
restoration unit) and LRSL records (luma rows and output of the cross-component
down-sampler, one per luma stripe).

As a script: lrc_dump.py --count <file>  prints the record counts.
"""
import struct
import sys

import numpy as np

# header words (int32) of the two record types, in file order
LRSC_HDR = ('plane', 'rtype', 'width', 'height', 'procunit_width', 'bit_depth',
            'base_qindex', 'qindex_offset', 'order_hint', 'v_start', 'h_start',
            'border_v', 'border_h', 'luma_border', 'n_pu', 'frame_w', 'frame_h',
            'ss_x', 'ss_y', 'ds_type', 'has_lossless_segment', 'num_classes',
            'has_luma', 'reserved')
LRSL_HDR = ('order_hint', 'frame_stripe', 'y0', 'y1', 'width_y', 'height_y',
            'width_uv', 'height_uv', 'ds_type', 'ss_x', 'ss_y', 'h_uv', 'above',
            'below', 'bit_depth', 'reserved')
TAPS_MAX = 32       # tap words of an LRSC record (the chroma filter has 18 taps)


def records(path):
    """Yield (kind, header dict, arrays dict) for every record of the file."""
    b = open(path, 'rb').read()
    i = 0
    while i < len(b):
        magic = b[i:i + 4].decode()
        i += 4
        if magic == 'LRSC':
            # header; restoration type of every processing unit (int32); the
            # chroma input of the stripe with its borders; the down-sampled
            # luma with its border; the taps (int16); the restored chroma
            # (samples: uint16, row by row)
            h = dict(zip(LRSC_HDR, struct.unpack_from('<24i', b, i)))
            i += 96
            w, hh = h['width'], h['height']
            bv, bh, lb = h['border_v'], h['border_h'], h['luma_border']
            pu = np.frombuffer(b, '<i4', h['n_pu'], i)
            i += 4 * h['n_pu']
            n = (hh + 2 * bv) * (w + 2 * bh)
            dgd = np.frombuffer(b, '<u2', n, i).reshape(hh + 2 * bv, w + 2 * bh)
            i += 2 * n
            n = (hh + 2 * lb) * (w + 2 * lb)
            luma = np.frombuffer(b, '<u2', n, i).reshape(hh + 2 * lb, w + 2 * lb)
            i += 2 * n
            taps = np.frombuffer(b, '<i2', TAPS_MAX, i)
            i += 2 * TAPS_MAX
            dst = np.frombuffer(b, '<u2', hh * w, i).reshape(hh, w)
            i += 2 * hh * w
            yield 'LRSC', h, {'pu_type': pu, 'dgd': dgd, 'luma': luma, 'taps': taps, 'dst': dst}
        elif magic == 'LRSL':
            # header; the luma rows of the stripe; their down-sampled version
            # at the chroma resolution
            h = dict(zip(LRSL_HDR, struct.unpack_from('<16i', b, i)))
            i += 64
            huv, wuv = h['h_uv'], h['width_uv']
            n = (2 * huv) * (2 * wuv)
            src = np.frombuffer(b, '<u2', n, i).reshape(2 * huv, 2 * wuv)
            i += 2 * n
            ds = np.frombuffer(b, '<u2', huv * wuv, i).reshape(huv, wuv)
            i += 2 * huv * wuv
            yield 'LRSL', h, {'src': src, 'ds': ds}
        else:
            raise ValueError(f'{path}: bad magic {magic!r} at {i - 4}')


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--count':
        cnt = {'LRSC': 0, 'LRSL': 0}
        planes = set()
        for kind, h, _ in records(sys.argv[2]):
            cnt[kind] += 1
            if kind == 'LRSC':
                planes.add(h['plane'])
        print(f"LRSC {cnt['LRSC']} (planes {sorted(planes)}) LRSL {cnt['LRSL']}")
    else:
        sys.exit(__doc__)
