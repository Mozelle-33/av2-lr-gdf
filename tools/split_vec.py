#!/usr/bin/env python3
"""Split a GDFV vector file (tb/tb_gdf.cpp format) into K parts at segment
boundaries, for parallel (gate-level) simulation.

Each part starts, after the reset of its own run, with the configuration state
at its first segment: the last write to every configuration address before it,
in the original order of these writes, followed by the part's own records.
Register slots and table entries are plain writes, so this reproduces the
state (also for aliased addresses).  Writes with side effects -- LR coefficient
staging/commit (0x1A00-0x1BFF), the LR write bank (odd addresses in
0x1C00-0x1DFF) and the PC-Wiener table (0x1E00-0x1FFF) -- are kept in full.
Records of type 5 (writes during the next segment) travel with their segment.

Usage: split_vec.py <in.vec> <K> <outdir>     (writes part_00.vec ...)
"""
import struct
import sys
from pathlib import Path


def side_effect(a):
    return 0x1A00 <= a <= 0x1BFF or (0x1C00 <= a <= 0x1DFF and a & 1) or 0x1E00 <= a <= 0x1FFF


def records(buf, pos):
    """Yield (type, start, end, writes) for every record; writes for type 1."""
    while pos < len(buf):
        t = buf[pos]
        if t == 0:
            return
        s = pos
        pos += 1
        if t == 1:
            (n,) = struct.unpack_from("<I", buf, pos)
            pos += 4
            w = struct.unpack_from("<%dH" % (2 * n), buf, pos)
            pos += 4 * n
            yield t, s, pos, w
            continue
        if t == 5:                      # writes during the next segment
            (n,) = struct.unpack_from("<I", buf, pos)
            pos += 4 + 8 * n
            yield t, s, pos, None
            continue
        if t == 6:                      # chroma LR segment (make_lrc_vectors.py)
            H, W, NCH, _id, WC, _chk = struct.unpack_from("<HHHIHB", buf, pos)
            pos += 13
            pos += (H + 4) // 2 * NCH * 16                   # luma words
            pos += 2 * (H // 2 + 4) * 2 * NCH * 2 + NCH      # chroma, side info
            pos += 2 * (H // 2) * WC * 2                     # expected U, V
            yield t, s, pos, None
            continue
        if t not in (2, 3, 4, 7):
            raise ValueError("unknown record %d at %d" % (t, s))
        H, W, NCH, _id = struct.unpack_from("<HHHI", buf, pos)
        pos += 10
        MR = MC = 0
        flags = 1
        if t in (3, 4, 7):
            MR, MC = struct.unpack_from("<HH", buf, pos)
            pos += 4
        if t == 3:
            flags = 2
        if t in (4, 7):
            flags = buf[pos]
            pos += 1
        npairs, ng = (H + 4) // 2, (W + 3) // 4
        size = 2 * npairs * NCH * 8                      # input words
        size += (H // 2) * ng * 16 if flags & 1 else 0   # err/corr
        size += MR * MC                                  # transform skip
        size += MR * MC if flags & 2 else 0              # classes
        size += 2 * H * W if flags & 4 else 0            # restored samples
        size += ng if flags & 8 else 0                   # LR info per group
        pos += size
        if t == 7:                      # joint unit + chroma (make_joint_vectors.py --lrc)
            (WC,) = struct.unpack_from("<H", buf, pos)
            pos += 3
            pos += 2 * (H // 2 + 4) * 2 * NCH * 2 + NCH      # chroma, side info
            pos += 2 * (H // 2) * WC * 2                     # expected U, V
        yield t, s, pos, None


def main():
    src, k, out = sys.argv[1], int(sys.argv[2]), Path(sys.argv[3])
    buf = open(src, "rb").read()
    if buf[:4] != b"GDFV":
        sys.exit("bad vector file")
    head = buf[:8]
    recs = list(records(buf, 8))
    segs = [i for i, r in enumerate(recs) if r[0] not in (1, 5)]
    per = -(-len(segs) // k)
    out.mkdir(parents=True, exist_ok=True)
    state = {}            # address -> (order, data) of the last plain write
    full = []             # (order, address, data) of side-effect writes
    order = 0
    ri = 0
    for p in range(k):
        first = segs[p * per] if p * per < len(segs) else None
        if first is None:
            break
        last = segs[min((p + 1) * per, len(segs)) - 1]
        # configuration writes before the part's first record
        start = first
        while start > 0 and recs[start - 1][0] in (1, 5) and start - 1 >= ri:
            start -= 1
        for r in recs[ri:start]:
            if r[0] == 1:
                w = r[3]
                for j in range(0, len(w), 2):
                    a, d = w[j], w[j + 1]
                    if side_effect(a):
                        full.append((order, a, d))
                    else:
                        state[a] = (order, d)
                    order += 1
        pre = sorted([(o, a, d) for a, (o, d) in state.items()] + full)
        body = b"".join(buf[r[1]:r[2]] for r in recs[start:last + 1])
        # later configuration records up to the next segment belong to the next part
        with open(out / ("part_%02d.vec" % p), "wb") as f:
            f.write(head)
            if pre:
                f.write(b"\x01" + struct.pack("<I", len(pre)))
                f.write(b"".join(struct.pack("<HH", a, d) for _, a, d in pre))
            f.write(body)
            f.write(b"\x00")
        # the state now includes the part's own writes
        for r in recs[start:last + 1]:
            if r[0] == 1:
                w = r[3]
                for j in range(0, len(w), 2):
                    a, d = w[j], w[j + 1]
                    if side_effect(a):
                        full.append((order, a, d))
                    else:
                        state[a] = (order, d)
                    order += 1
        ri = last + 1
        print("part %02d: segments %d..%d, %d preamble writes" %
              (p, segs.index(first), segs.index(last), len(pre)))


if __name__ == "__main__":
    main()
