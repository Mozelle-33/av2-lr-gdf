#!/usr/bin/env python3
"""Test vectors for the PC-Wiener classifier of gdf_core (PCW = 1) from the
processing-unit dumps of the instrumented AVM decoder (AVM_PCW_DUMP).

Each processing unit becomes one segment record of type 3 (same .vec file
format as tools/make_vectors.py):
    u8 3  PCW SEG : u16 H, u16 W, u16 NCH, u32 id, u16 MI_ROWS, u16 MI_COLS,
                    u16 in[(H+4)/2][NCH][8]      (as record type 2)
                    u8  tskip[MI_ROWS][MI_COLS]  transform-skip flags
                    u8  cls[MI_ROWS][MI_COLS]    expected PC-Wiener class
preceded by the configuration writes of the unit: the 37 x 4 rows of
qval_given_tskip_lut used by the classifier (0x1E00 + (t<<3) + (f<<1) + hi)
and the mode word (bit depth, tskip_zero_flag).  The GDF outputs of these
segments are not checked.

Usage: make_pcw_vectors.py <out.vec> <dump.pcwdump> [...] [--max N]
"""
import struct
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "analysis"))
from pcw_golden import read_records  # noqa: E402


def main(argv):
    max_units = None
    if "--max" in argv:
        i = argv.index("--max")
        max_units = int(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
    out, paths = argv[0], argv[1:]
    n = 0
    with open(out, "wb") as f:
        f.write(b"GDFV" + struct.pack("<I", 1))
        for p in paths:
            for rec in read_records(p):
                h, w, bv, bh = rec["height"], rec["width"], rec["bv"], rec["bh"]
                assert h % 2 == 0 and bv >= 2 and bh >= 4
                wr = []
                for t in range(37):
                    for fe in range(4):
                        v = int(rec["qval_lut"][7 * t, fe]) & 0x3FFFFFF
                        base = 0x1E00 + (t << 3) + (fe << 1)
                        wr += [(base, v & 0xFFFF), (base + 1, v >> 16)]
                mode = (1 if rec["bit_depth"] >= 10 else 0) << 1 | (rec["tskip_zero"] << 4)
                wr.append((0x1C00, mode))
                f.write(struct.pack("<BI", 1, len(wr)))
                f.write(b"".join(struct.pack("<HH", a, d) for a, d in wr))
                # window rows -2..h+1, columns -6..w+5 (the dump holds -4..w+3;
                # the two outer columns only feed GDF features, replicate them)
                d = rec["dgd"]
                rows = d[bv - 2:bv + h + 2, :]
                rows = np.concatenate([rows[:, :1], rows[:, :1], rows[:, bh - 4:],
                                       rows[:, -1:], rows[:, -1:]], axis=1)
                rows = rows[:, :w + 12]
                nch = (w + 12 + 3) // 4
                buf = np.zeros((h + 4, nch * 4), np.uint16)
                buf[:, :w + 12] = rows
                pairs = buf.reshape((h + 4) // 2, 2, nch, 4).transpose(0, 2, 1, 3)
                mr, mc = rec["mi_rows"], rec["mi_cols"]
                f.write(struct.pack("<BHHHIHH", 3, h, w, nch, n, mr, mc))
                f.write(pairs.astype("<u2").tobytes())
                f.write(rec["tskip"].astype(np.uint8).tobytes())
                f.write(rec["cls"].astype(np.uint8).tobytes())
                n += 1
                if max_units is not None and n >= max_units:
                    break
            if max_units is not None and n >= max_units:
                break
        f.write(struct.pack("<B", 0))
    print(f"wrote {n} PC-Wiener segments to {out}")


if __name__ == "__main__":
    main(sys.argv[1:])
