#!/usr/bin/env python3
"""Drop every configuration write of a GDFV vector file that leaves the
configuration state unchanged, so that the segments of a frame run nearly
back to back (power windows).  Finer than dedup_cfg.py, which drops only
whole records that repeat the previous one: with the chroma LR, the edge
flags and taps differ from unit to unit, so few records repeat as a whole.

State model (rtl/gdf_core.v): plain registers and table entries are written
directly; the PC-Wiener Q tables (0x1E00-0x1FFF) are written as (lo, hi)
pairs, hi commits the entry, and a pair is dropped when it commits the value
the entry already holds; the LR coefficient memory (0x1A00-0x1BFF, seven
staging words and a commit) is kept as written (make_joint_vectors.py emits
it only when the coefficients change).  Writes during a segment (record 5)
are kept and update the state.

Usage: dedup_writes.py <in.vec> <out.vec>
"""
import struct
import sys

from split_vec import records


def main():
    src, dst = sys.argv[1], sys.argv[2]
    buf = open(src, "rb").read()
    if buf[:4] != b"GDFV":
        sys.exit("bad vector file")
    out = [buf[:8]]
    state = {}            # plain address -> value; ("q", lo address) -> (lo, hi)
    kept = dropped = 0

    # addresses that are written directly (neither the LR coefficient memory
    # nor the PC-Wiener Q tables)
    def plain(a):
        return not (0x1A00 <= a <= 0x1BFF or 0x1E00 <= a <= 0x1FFF)

    for t, s, e, w in records(buf, 8):
        if t == 5:
            # writes during a segment: kept, they update the state
            n = struct.unpack_from("<I", buf, s + 1)[0]
            ws = struct.unpack_from("<%dH" % (4 * n), buf, s + 5)
            for j in range(n):           # (at, addr, data) as 32 + 16 + 16 bits
                a, d = ws[4 * j + 2], ws[4 * j + 3]
                if plain(a):
                    state[a] = d
            out.append(buf[s:e])
            continue
        if t != 1:
            out.append(buf[s:e])     # segments and other records: unchanged
            continue
        # configuration record: (address, data) pairs
        pairs = [(w[j], w[j + 1]) for j in range(0, len(w), 2)]
        new = []
        j = 0
        while j < len(pairs):
            a, d = pairs[j]
            # a (lo, hi) pair of a Q table entry: dropped if the entry holds it
            if 0x1E00 <= a <= 0x1FFF and not a & 1 and j + 1 < len(pairs) and pairs[j + 1][0] == a + 1:
                v = (d, pairs[j + 1][1])
                if state.get(("q", a)) == v:
                    dropped += 2
                else:
                    state[("q", a)] = v
                    new += [pairs[j], pairs[j + 1]]
                    kept += 2
                j += 2
                continue
            if plain(a):             # dropped if the register holds the value
                if state.get(a) == d:
                    dropped += 1
                else:
                    state[a] = d
                    new.append((a, d))
                    kept += 1
            else:                    # LR coefficient memory: as written
                new.append((a, d))
                kept += 1
            j += 1
        if new:                      # a record without writes left is dropped
            out.append(struct.pack("<BI", 1, len(new)))
            out.append(b"".join(struct.pack("<HH", a, d) for a, d in new))
    out.append(b"\x00")
    open(dst, "wb").write(b"".join(out))
    print(f"writes kept {kept}, dropped {dropped}")


if __name__ == "__main__":
    main()
