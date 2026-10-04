#!/usr/bin/env python3
"""Synthetic stress segments for the chroma LR of the joint core (CH = 1), as
type-6 records of a .vec file (tools/make_lrc_vectors.py).

Every segment is a chroma stripe of one to four restoration units of 32 to
128 chroma columns (4:2:0): random, extreme and structured luma and chroma (8
and 10 bit), the three down-sampling filters, the picture-edge flags, up to
four filters per plane in the coefficient banks, selected per strip by the
side stream, taps random in, or at the ends of, the ranges of the syntax
(wienerns_coeff_uv: 6, 6, 5, 5, 5 x 6, 4 x 8 bits from -24, -24, -14, -14,
-16, -8), and some 32-column processing units with LR off.  The expected
outputs are those of the bit-exact model (analysis/lrc_golden.py), which
reproduces every decoder dump: down-sampled luma rows -2..H/2+1 from the luma
rows -2..H+1 (rows beyond repeat the outermost one), replicated at the
flagged picture edges.

Usage: make_lrc_stress.py <out.vec> <segments> <seed>
"""
import struct
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "analysis"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from lrc_golden import chroma_filter, downsample  # noqa: E402
from make_lr_stress import PATTERNS, samples  # noqa: E402

TAP_RANGE = [(6, -24), (6, -24), (5, -14), (5, -14)] + [(5, -16)] * 6 + [(4, -8)] * 8
PW = 32                                    # chroma processing unit


def rand_taps(rng):
    mode = rng.choice(["rand", "ends", "max", "min", "small"])
    t = []
    for bits, lo in TAP_RANGE:
        hi = lo + (1 << bits) - 1
        t.append(int({"rand": rng.integers(lo, hi + 1), "ends": rng.choice([lo, hi]),
                      "max": hi, "min": lo, "small": rng.integers(-2, 3)}[mode]))
    return tuple(t)


def field(rng, h, w, mx):
    """Samples in vertical bands of different patterns."""
    x = np.zeros((h, w), np.int64)
    c = 0
    while c < w:
        bw = int(rng.choice([8, 16, 32, 64, w]))
        x[:, c:c + bw] = samples(rng, rng.choice(PATTERNS), h, min(bw, w - c), mx)
        c += bw
    return x


def main(argv):
    out, n_seg, seed = argv[0], int(argv[1]), int(argv[2])
    rng = np.random.default_rng(seed)
    buf = bytearray(b"GDFV" + struct.pack("<I", 1))
    st = {"segs": 0, "units": 0, "samples": 0, "off_pu": 0, "edges": 0}
    for sid in range(n_seg):
        bd = int(rng.choice([8, 10]))
        mx = (1 << bd) - 1
        H = int(rng.choice([64, 64, 64, 56, 48, 32, 16, 8]))
        hh = H // 2
        widths = [int(rng.choice([32, 32, 64, 96, 128])) for _ in range(int(rng.integers(1, 5)))]
        while sum(widths) > 480:
            widths.pop()
        wc = sum(widths)
        W = 2 * wc
        nch = (W + 12) // 4
        ds_type = int(rng.integers(0, 3))
        top, bot, left, right = (int(rng.random() < 0.15) for _ in range(4))
        lum = field(rng, H + 4, 4 * nch, mx)             # rows -2..H+1, columns -6..
        chroma = np.stack([field(rng, hh + 4, 2 * nch, mx) for _ in range(2)])  # rows -2.., columns -4..
        # down-sampled luma rows -2..hh+1, columns -2..wc+1
        lext = np.concatenate([lum[:1], lum[:1], lum, lum[-1:], lum[-1:]])
        ds = downsample(lext[:, 2:], ds_type, hh + 4, wc + 4)
        if top:
            ds[:2] = ds[2]
        if bot:
            ds[hh + 2:] = ds[hh + 1]
        if left:
            ds[:, :2] = ds[:, 2:3]
        if right:
            ds[:, wc + 2:] = ds[:, wc + 1:wc + 2]
        # filters: unit u of plane f uses bank bank[f][u] (at most four per plane)
        banks = [[], []]
        ubank = [[], []]
        for f in (0, 1):
            for _ in widths:
                if len(banks[f]) < 4 and (not banks[f] or rng.random() < 0.7):
                    banks[f].append(rand_taps(rng))
                    ubank[f].append(len(banks[f]) - 1)
                else:
                    ubank[f].append(int(rng.integers(len(banks[f]))))
        exp = np.zeros((2, hh, wc), np.int64)
        side = np.zeros(nch, np.uint8)
        starts = np.cumsum([0] + widths)
        for f in (0, 1):
            dgd = chroma[f][:, 2:wc + 6]                  # columns -2..wc+1
            exp[f] = chroma[f][2:hh + 2, 4:wc + 4]        # LR off: the input
            for u, wu in enumerate(widths):
                y = chroma_filter(dgd, 2, 2, ds, 2, banks[f][ubank[f][u]], hh, wc, bd)
                for p in range(wu // PW):
                    x0 = int(starts[u]) + p * PW
                    if rng.random() < 0.1:
                        st["off_pu"] += 1
                        continue
                    exp[f][:, x0:x0 + PW] = y[:, x0:x0 + PW]
                    for c in range((x0 + 4) // 2, (x0 + PW + 4) // 2):
                        side[c] |= (4 | ubank[f][u]) << (3 * f)
        cfg = [(0x1C00, 2 if bd == 10 else 0),
               (0x1C02, 1 | (ds_type << 1) | (top << 3) | (bot << 4) | (left << 5) | (right << 6))]
        for f in (0, 1):
            for b, t in enumerate(banks[f]):
                cfg += [(0x1D00 + (f << 7) + (b << 5) + k, t[k] & 0xFFFF) for k in range(18)]
        words = np.zeros(((H + 4) // 2, nch, 8), np.uint16)
        for p in range((H + 4) // 2):
            for c in range(nch):
                words[p, c, 0:4] = lum[2 * p, 4 * c:4 * c + 4]
                words[p, c, 4:8] = lum[2 * p + 1, 4 * c:4 * c + 4]
        buf += struct.pack("<BI", 1, len(cfg))
        for adr, val in cfg:
            buf += struct.pack("<HH", adr, val)
        buf += struct.pack("<BHHHIHB", 6, H, W, nch, sid, wc, 3)
        buf += words.tobytes() + chroma.astype(np.uint16).tobytes() + side.tobytes() + \
            exp.astype(np.uint16).tobytes()
        st["segs"] += 1
        st["units"] += len(widths)
        st["samples"] += 2 * hh * wc
        st["edges"] += top + bot + left + right
    buf += b"\x00"
    open(out, "wb").write(buf)
    print(f"wrote {out}: {st}")


if __name__ == "__main__":
    main(sys.argv[1:])
