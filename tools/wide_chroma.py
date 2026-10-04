#!/usr/bin/env python3
"""Chroma part of a full-width segment of the joint stage (CH = 1), for
tools/make_wide_vectors.py --lrc: the chroma restoration units of a stripe row
from the chroma LR dump (AVM_LRC_DUMP: the units with LR) and, if present
beside it, from <stream>.lrcoff (AVM_LRCOFF_DUMP: the units with LR off, whose
output is their input).
"""
import struct
from pathlib import Path

import numpy as np

from lrc_dump import records as lrc_records
from lrc_golden import downsample

RESTORE_NONE = 0


def read_lrc(path):
    """{v_start: [(header, arrays)]} of the LRSC records of a .lrcdump and of
    the .lrcoff beside it.  header["frame"] is the index of the frame (the
    LRSL records with frame_stripe 0 before the record, minus one; the header
    word "reserved" in the .lrcoff), header["none"] marks a unit with LR off."""
    lrcs = {}
    frame = -1
    for kind, hdr, arr in lrc_records(path):
        if kind == "LRSL":
            frame += hdr["frame_stripe"] == 0
        elif hdr["num_classes"] == 1 and hdr["has_luma"] and hdr["has_lossless_segment"] <= 0:
            hdr["frame"], hdr["none"] = frame, False
            lrcs.setdefault(hdr["v_start"], []).append((hdr, arr))
    off = Path(path).with_suffix(".lrcoff")
    if off.exists() and off.stat().st_size:
        for kind, hdr, arr in lrc_records(str(off)):
            if hdr["has_lossless_segment"] <= 0:
                hdr["frame"], hdr["none"] = hdr["reserved"], True
                lrcs.setdefault(hdr["v_start"], []).append((hdr, arr))
    return lrcs


def wide_chroma(lrcs, units, c0, c1):
    """Chroma part of the segment over the stripe columns c0..c1-1: (config
    writes, record data, checked samples, restoration units with LR), or None
    if the chroma row of a plane is not complete in the dumps, the borders of
    adjacent units disagree or a plane needs more than four filters.  The
    frame is the one whose chroma stripes have the down-sampled luma of the
    luma stripe."""
    u0 = units[0]
    a, h, i0 = u0["apron"], u0["h"], u0["i_min"]
    w = c1 - c0
    hh, wc, xc0 = h // 2, w // 2, c0 // 2
    if h % 4 or w % 4:
        return None
    nch = (w + 12 + 3) // 4
    src = np.concatenate([u["win"][a:a + h, a:a + u["w"]] for u in units], axis=1)
    cand = [t for t in lrcs.get(i0 // 2, []) if t[0]["height"] == hh]
    frames = set()
    for hdr, arr in cand:
        x0, wr = hdr["h_start"], hdr["width"]
        if hdr["none"] or 2 * (x0 + wr) > src.shape[1]:
            continue
        lb = hdr["luma_border"]
        ds = downsample(src[:, 2 * x0:2 * (x0 + wr)], hdr["ds_type"], hh, wr)
        if np.array_equal(ds, arr["luma"][lb:lb + hh, lb:lb + wr].astype(np.int64)):
            frames.add(hdr["frame"])
    if len(frames) != 1:
        return None                            # no chroma LR here, or ambiguous
    frame = frames.pop()
    cover, banks = {}, {}
    for p in (1, 2):
        recs = sorted((t for t in cand if t[0]["plane"] == p and t[0]["frame"] == frame),
                      key=lambda t: t[0]["h_start"])
        if not recs:
            continue                            # plane without LR in the frame
        x = 0
        for hdr, arr in recs:                  # the units tile the chroma row
            if hdr["h_start"] != x:
                return None
            x += hdr["width"]
        if x != recs[0][0]["frame_w"]:
            return None
        for (h0, a0), (h1, a1) in zip(recs, recs[1:]):
            # the borders of the units with LR agree with their neighbours'
            # samples (a unit without LR holds the frame, not the stripe
            # buffer: only its rows inside the stripe are compared)
            r0, r1 = (2, hh + 2) if h0["none"] or h1["none"] else (0, hh + 4)
            b0, b1, w0 = h0["border_h"], h1["border_h"], h0["width"]
            n = min(b0, b1)
            d0 = a0["dgd"][h0["border_v"] - 2:h0["border_v"] + hh + 2]
            d1 = a1["dgd"][h1["border_v"] - 2:h1["border_v"] + hh + 2]
            if not ((d0[r0:r1, b0 + w0:b0 + w0 + n] == d1[r0:r1, b1:b1 + n]).all() and
                    (d1[r0:r1, b1 - n:b1] == d0[r0:r1, b0 + w0 - n:b0 + w0]).all()):
                return None
        cover[p] = recs
        banks[p] = []
        for hdr, arr in recs:
            if not hdr["none"] and hdr["h_start"] < xc0 + wc and hdr["h_start"] + hdr["width"] > xc0:
                t = tuple(int(v) for v in arr["taps"][:18])
                if t not in banks[p]:
                    banks[p].append(t)
        if len(banks[p]) > 4:
            return None
    present = sorted(cover)
    if not present or not any(banks[p] for p in present):
        return None

    def rows(hdr, arr):
        return arr["dgd"][hdr["border_v"] - 2:hdr["border_v"] + hh + 2]

    def column(recs, x):
        """Rows -2..hh+1 of chroma column x: from the unit that holds it, or,
        within the border of an adjacent unit with LR, from that border (the
        samples that its filter reads)."""
        k = len(recs) - 1
        for i, (hdr, arr) in enumerate(recs):
            if x < hdr["h_start"] + hdr["width"]:
                k = i
                break
        hdr, arr = recs[k]
        if hdr["none"]:
            for nb in (k - 1, k + 1):
                if 0 <= nb < len(recs) and not recs[nb][0]["none"]:
                    h2, a2 = recs[nb]
                    i2 = x - h2["h_start"] + h2["border_h"]
                    if 0 <= i2 < a2["dgd"].shape[1]:
                        return rows(h2, a2)[:, i2]
        d = rows(hdr, arr)
        return d[:, min(max(x - hdr["h_start"] + hdr["border_h"], 0), d.shape[1] - 1)]

    def unit_of(recs, x):
        for hdr, arr in recs:
            if x < hdr["h_start"] + hdr["width"]:
                return hdr, arr
        return recs[-1]

    # input rows -2..hh+1 of every strip, expected output and side info (LR
    # on, bank) of both planes
    chroma = np.zeros((2, hh + 4, 2 * nch), np.uint16)
    exp = np.zeros((2, hh, wc), np.uint16)
    side = np.zeros(nch, np.uint8)
    chk = 0
    for f in (0, 1):
        recs = cover.get(1 + f, cover[present[0]])
        for i, x in enumerate(range(xc0 - 4, xc0 + 2 * nch - 4)):
            chroma[f, :, i] = column(recs, x)
        if (1 + f) not in cover:
            continue                            # plane without LR: fed, not checked
        chk |= 1 << f
        exp[f] = np.concatenate([arr["dst"] for hdr, arr in recs], axis=1)[:, xc0:xc0 + wc]
        for c in range(nch):
            x = xc0 + 2 * c - 4
            if xc0 <= x < xc0 + wc:
                hdr, arr = unit_of(recs, x)
                if not hdr["none"] and \
                        arr["pu_type"][(x - hdr["h_start"]) // hdr["procunit_width"]] != RESTORE_NONE:
                    t = tuple(int(v) for v in arr["taps"][:18])
                    side[c] |= (4 | banks[1 + f].index(t)) << (3 * f)
    hd = cover[present[0]][0][0]
    v0 = hd["v_start"]
    top, bot = v0 == 0, v0 + hh == hd["frame_h"]
    left, right = xc0 == 0, xc0 + wc == hd["frame_w"]
    ds = hd["ds_type"] if hd["ds_type"] in (0, 1, 2) else 0
    cfg = [(0x1C02, 1 | (ds << 1) | (top << 3) | (bot << 4) | (left << 5) | (right << 6))]
    for f in (0, 1):
        for b, t in enumerate(banks.get(1 + f, [])):
            cfg += [(0x1D00 + (f << 7) + (b << 5) + k, t[k] & 0xFFFF) for k in range(18)]
    data = (struct.pack("<HB", wc, chk) + chroma.astype("<u2").tobytes() + side.tobytes() +
            exp.astype("<u2").tobytes())
    nru = sum(1 for p in cover for hdr, arr in cover[p]
              if not hdr["none"] and hdr["h_start"] < xc0 + wc and hdr["h_start"] + hdr["width"] > xc0)
    return cfg, data, hh * wc * bin(chk).count("1"), nru
