#!/usr/bin/env python3
"""Test vectors for the joint LR/GDF core (gdf_core, VS = 1, PCW = 1, LR = 1)
from the LR stripe dumps of the instrumented AVM decoder (AVM_LR_DUMP).

Every 64-column processing unit of a stripe becomes one segment record of
type 4 (same .vec file format as tools/make_vectors.py):
    u8 4  JOINT SEG : u16 H, u16 W, u16 NCH, u32 id, u16 MI_ROWS, u16 MI_COLS,
                      u8 flags (1: GDF err/corr, 2: LR classes, 4: restored y),
                      u16 in[(H+4)/2][NCH][8]      (as record type 2)
                      [flags & 1] i8 exp[H/2][W/4][8][2]  (as record type 2)
                      u8  tskip[MI_ROWS][MI_COLS]
                      [flags & 2] u8 cls[MI_ROWS][MI_COLS]
                      [flags & 4] u16 y[H][W]     (native bit depth)
preceded by its configuration writes: the rows of qval_given_tskip_lut, the
64 coefficient entries of the LR filter (only when they change) and the mode
word (GDF off, LR on unless the unit is RESTORE_NONE).

Coefficient entry f (the 64-filter index of the class): PC-Wiener: filter f
of the quantizer set; Wiener-NS: the taps of the sub-class to_n(f) (every
sub-classifier is a function of the 64-filter index), centre 128 - 2 sum.

With --stripes, up to four adjacent restoration units of a stripe (at most
500 columns) form one segment instead: unit i is written to coefficient bank
i and the per-group side stream selects it (record flag 8), which tests the
switching of restoration units within a stripe.
                      [flags & 8] u8 lr[W/4]      {LR on, bank} per group

Usage: make_lr_vectors.py <out.vec> <dump.lrdump> [...] [--max N] [--stripes]
"""
import struct
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "analysis"))
from lr_golden import (BANK, SUBCLS, RESTORE_NONE, RESTORE_PC_WIENER,  # noqa: E402
                       read_records)


# coefficient entry of gdf_core (LR = 1): tap k at [LOFF[k] +: LW[k]], signed,
# the exact ranges of the PC-Wiener banks and the Wiener-NS syntax; centre
# tap (10 bit) at 95
LW = [8, 8, 7, 6, 7, 7, 6, 7, 6, 6, 5, 6, 4, 4, 4, 4]
LOFF = [sum(LW[:k]) for k in range(16)]
CENTRE_OFF = sum(LW)                     # 95


def coef_table(rec):
    """64 entries x (16 taps, centre)."""
    s = rec["set_index"]
    tab = np.zeros((64, 17), np.int64)
    if rec["rtype"] == RESTORE_PC_WIENER:
        tab[:, :12] = BANK[s][:, :12]
        tab[:, 16] = 128 + BANK[s][:, 12]
    else:
        n = rec["num_classes"]
        taps = rec["taps"][:, :16]
        for f in range(64):
            cl = np.nonzero(SUBCLS[64][s] == f)[0]
            if n > 1:
                if cl.size == 0:
                    continue
                subs = set(int(SUBCLS[n][s][c]) for c in cl)
                assert len(subs) == 1, (s, n, f, subs)
                sub = subs.pop()
            else:
                sub = 0
            tab[f, :16] = taps[sub]
            tab[f, 16] = 128 - 2 * int(taps[sub].sum())
    for k in range(16):
        lim = 1 << (LW[k] - 1)
        assert (tab[:, k] >= -lim).all() and (tab[:, k] < lim).all(), k
    assert (tab[:, 16] >= -512).all() and (tab[:, 16] <= 511).all()
    return tab


def coef_writes(tab, bank=0):
    wr = [(0x1C01, bank)]                  # write bank of the coefficient memory
    for f in range(64):
        v = 0
        for k in range(16):
            v |= (int(tab[f, k]) & ((1 << LW[k]) - 1)) << LOFF[k]
        v |= (int(tab[f, 16]) & 0x3FF) << CENTRE_OFF
        for w in range(8):
            wr.append((0x1A00 + (f << 3) + w, (v >> (16 * w)) & 0xFFFF))
    return wr


def stripe_groups(paths, max_ru, max_w):
    """Runs of up to max_ru consecutive restoration-unit stripes of one frame
    stripe (same order hint and rows, adjacent columns, max_w columns)."""
    for p in paths:
        run = []
        for rec in read_records(p):
            if rec["has_lossless"] or rec["skip_pcw"] or rec["class_restrict"] >= 0:
                continue
            if run:
                r0, rl = run[0], run[-1]
                if (rec["order_hint"], rec["v_start"], rec["height"]) == \
                        (r0["order_hint"], r0["v_start"], r0["height"]) and \
                        rec["h_start"] == rl["h_start"] + rl["width"] and \
                        len(run) < max_ru and \
                        sum(r["width"] for r in run) + rec["width"] <= max_w:
                    run.append(rec)
                    continue
                yield run
            run = [rec]
        if run:
            yield run


def write_stripe_seg(f, run, n):
    """One segment over the restoration units of run, unit i in bank i."""
    r0 = run[0]
    h, bv, bh = r0["height"], r0["bv"], r0["bh"]
    w = sum(r["width"] for r in run)
    wr = []
    qsrc = next((r for r in run if r["rtype"] == RESTORE_PC_WIENER or r["num_classes"] > 1), r0)
    for t in range(37):
        for fe in range(4):
            v = int(qsrc["qval_lut"][7 * t, fe]) & 0x3FFFFFF
            base = 0x1E00 + (t << 3) + (fe << 1)
            wr += [(base, v & 0xFFFF), (base + 1, v >> 16)]
    for i, r in enumerate(run):
        wr += coef_writes(coef_table(r), bank=i)
    mode = ((1 if r0["bit_depth"] >= 10 else 0) << 1 | r0["tskip_zero"] << 4 | 1 << 6 |
            r0["set_index"] << 7)
    wr.append((0x1C00, mode))
    # configuration record, then the segment
    f.write(struct.pack("<BI", 1, len(wr)))
    f.write(b"".join(struct.pack("<HH", a, v) for a, v in wr))
    # window: columns -6..w+5 from the unit that holds them (clamped at the ends)
    cols = []
    for x in range(-6, w + 6):
        xc = min(max(x, -bh), w + bh - 1)
        k = 0
        while k + 1 < len(run) and xc >= sum(r["width"] for r in run[:k + 1]):
            k += 1
        xs = xc - sum(r["width"] for r in run[:k])
        cols.append(run[k]["dgd"][bv - 2:bv + h + 2, xs + bh])
    win = np.stack(cols, axis=1)
    nch = (w + 12 + 3) // 4
    buf = np.zeros((h + 4, nch * 4), np.uint16)
    buf[:, :w + 12] = win
    pairs = buf.reshape((h + 4) // 2, 2, nch, 4).transpose(0, 2, 1, 3)
    mr, mc = r0["mi_rows"], (w + 3) // 4
    chk_cls = all(r["rtype"] == RESTORE_PC_WIENER or r["num_classes"] > 1 for r in run)
    flags = (2 if chk_cls else 0) | 4 | 8
    f.write(struct.pack("<BHHHIHHB", 4, h, w, nch, n, mr, mc, flags))
    f.write(pairs.astype("<u2").tobytes())
    f.write(np.concatenate([r["tskip"] for r in run], axis=1).astype(np.uint8).tobytes())
    if chk_cls:
        f.write(np.concatenate([r["cls"] for r in run], axis=1).astype(np.uint8).tobytes())
    f.write(np.concatenate([r["dst"] for r in run], axis=1).astype("<u2").tobytes())
    lri = []
    for i, r in enumerate(run):
        for g in range((r["width"] + 3) // 4):
            on = r["pu_type"][(4 * g) // r["procunit_width"]] != RESTORE_NONE
            lri.append((4 if on else 0) | i)
    f.write(bytes(lri))
    return len(run)


def main_stripes(out, paths, max_segs, max_ru, max_w):
    n = rus = 0
    with open(out, "wb") as f:
        f.write(b"GDFV" + struct.pack("<I", 1))
        for run in stripe_groups(paths, max_ru, max_w):
            if len(run) < 2:
                continue                       # single units: PU mode covers them
            rus += write_stripe_seg(f, run, n)
            n += 1
            if max_segs is not None and n >= max_segs:
                break
        f.write(struct.pack("<B", 0))
    print(f"wrote {n} multi-unit LR segments ({rus} restoration units) to {out}")


def main(argv):
    max_segs = None
    if "--max" in argv:
        i = argv.index("--max")
        max_segs = int(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
    if "--stripes" in argv:                # segments over up to 4 units
        argv = [a for a in argv if a != "--stripes"]
        return main_stripes(argv[0], argv[1:], max_segs, 4, 500)
    out, paths = argv[0], argv[1:]
    n = 0
    last_tab = None
    stats = {"pcw": 0, "wns": 0, "none": 0}
    with open(out, "wb") as f:
        f.write(b"GDFV" + struct.pack("<I", 1))
        for p in paths:
            for rec in read_records(p):
                if rec["has_lossless"] or rec["skip_pcw"] or rec["class_restrict"] >= 0:
                    continue
                h, wst, bv, bh = rec["height"], rec["width"], rec["bv"], rec["bh"]
                assert h % 4 == 0 and bv >= 2 and bh >= 4
                tab = coef_table(rec)
                pcw = rec["rtype"] == RESTORE_PC_WIENER
                chk_cls = pcw or rec["num_classes"] > 1
                pw = rec["procunit_width"]
                d = rec["dgd"]
                # one segment per 64-column processing unit of the stripe
                for pu in range(rec["n_pu"]):
                    x0 = pu * pw
                    wp = min(pw, wst - x0)
                    assert wp % 4 == 0
                    lr_on = rec["pu_type"][pu] != RESTORE_NONE
                    wr = []
                    for t in range(37):
                        for fe in range(4):
                            v = int(rec["qval_lut"][7 * t, fe]) & 0x3FFFFFF
                            base = 0x1E00 + (t << 3) + (fe << 1)
                            wr += [(base, v & 0xFFFF), (base + 1, v >> 16)]
                    if last_tab is None or not np.array_equal(tab, last_tab):
                        wr += coef_writes(tab)
                        last_tab = tab
                    mode = ((1 if rec["bit_depth"] >= 10 else 0) << 1 |
                            rec["tskip_zero"] << 4 | (1 if lr_on else 0) << 6 |
                            rec["set_index"] << 7)
                    wr.append((0x1C00, mode))
                    f.write(struct.pack("<BI", 1, len(wr)))
                    f.write(b"".join(struct.pack("<HH", a, v) for a, v in wr))
                    # window rows -2..h+1, columns x0-6..x0+wp+5 (clamped to the
                    # dumped -4..wst+3; the outer columns only feed GDF features)
                    cols = np.clip(np.arange(x0 - 6, x0 + wp + 6), -bh, wst + bh - 1) + bh
                    rows = d[bv - 2:bv + h + 2][:, cols]
                    nch = (wp + 12 + 3) // 4
                    buf = np.zeros((h + 4, nch * 4), np.uint16)
                    buf[:, :wp + 12] = rows
                    pairs = buf.reshape((h + 4) // 2, 2, nch, 4).transpose(0, 2, 1, 3)
                    mr, m0, mc = rec["mi_rows"], x0 // 4, (wp + 3) // 4
                    flags = (2 if chk_cls else 0) | 4 | 8
                    f.write(struct.pack("<BHHHIHHB", 4, h, wp, nch, n, mr, mc, flags))
                    f.write(pairs.astype("<u2").tobytes())
                    f.write(np.ascontiguousarray(rec["tskip"][:, m0:m0 + mc]).astype(np.uint8).tobytes())
                    if chk_cls:
                        f.write(np.ascontiguousarray(rec["cls"][:, m0:m0 + mc]).astype(np.uint8).tobytes())
                    f.write(np.ascontiguousarray(rec["dst"][:, x0:x0 + wp]).astype("<u2").tobytes())
                    f.write(bytes([4] * ((wp + 3) // 4)))      # LR on, bank 0
                    stats["pcw" if pcw else "wns"] += 1
                    stats["none"] += 0 if lr_on else 1
                    n += 1
                    if max_segs is not None and n >= max_segs:
                        break
                if max_segs is not None and n >= max_segs:
                    break
            if max_segs is not None and n >= max_segs:
                break
        f.write(struct.pack("<B", 0))
    print(f"wrote {n} LR segments to {out}: {stats}")


if __name__ == "__main__":
    main(sys.argv[1:])
