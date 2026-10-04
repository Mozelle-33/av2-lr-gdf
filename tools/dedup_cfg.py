#!/usr/bin/env python3
"""Drop every configuration record of a GDFV vector file that repeats the
previous configuration record exactly, so that the segments of one frame run
back to back (e.g., for a power window).  A repeated record rewrites the same
values, and every table commit in it follows its own staging writes, so the
configuration state is unchanged.

Usage: dedup_cfg.py <in.vec> <out.vec>
"""
import sys

from split_vec import records


def main():
    src, dst = sys.argv[1], sys.argv[2]
    buf = open(src, "rb").read()
    if buf[:4] != b"GDFV":
        sys.exit("bad vector file")
    out = [buf[:8]]
    prev = None
    dropped = kept = 0
    for t, s, e, w in records(buf, 8):
        if t == 1:
            if w == prev:
                dropped += 1
                continue
            prev = w
            kept += 1
        out.append(buf[s:e])
    out.append(b"\x00")
    open(dst, "wb").write(b"".join(out))
    print("configuration records kept %d, dropped %d" % (kept, dropped))


if __name__ == "__main__":
    main()
