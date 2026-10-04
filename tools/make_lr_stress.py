#!/usr/bin/env python3
"""Synthetic stress stripes for the luma LR of the joint core, written as an
.lrdump file (LRSU records as of AVM_LR_DUMP) so that tools/make_lr_vectors.py
turns them into unit segments and, with --stripes, into segments over several
restoration units.

Every stripe is a row of one to four restoration units of 64 to 192 columns
with random, extreme and structured samples (8 and 10 bit), random
transform-skip flags, and per unit either PC-Wiener (all four quantizer sets)
or Wiener-NS with 1 to 16 filters whose taps are random in, or at the ends of,
the ranges of the syntax (wienerns_coeff_large_y: 6, 6, 5, 5, 5, 5, 4, ... bits
from -24, -24, -14, -14, -16, -16, -8, ...); some processing units are
RESTORE_NONE.  The classes and the filter outputs are those of the bit-exact
models (analysis/pcw_golden.py, analysis/lr_golden.py), which reproduce every
decoder dump; the tables qval_given_tskip_lut are taken from decoder dumps.

With --set S every stripe uses quantizer set S, with --pcw P a unit is
PC-Wiener with probability P (default 0.4), and --patterns a,b,... restricts
the sample patterns (directed runs that complete the class coverage).

Usage: make_lr_stress.py <out.lrdump> <stripes> <seed> <real.lrdump> [...]
                         [--set S] [--pcw P] [--patterns a,b,...]
"""
import struct
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "analysis"))
import pcw_golden  # noqa: E402
from lr_golden import (HDR_FIELDS, RESTORE_NONE, RESTORE_PC_WIENER,  # noqa: E402
                       RESTORE_WIENER_NONSEP, lr_filter, read_records)

BV = BH = 4
PW = 64
# Wiener-NS luma syntax: (bits, minimum) of the 16 taps
TAP_RANGE = [(6, -24), (6, -24), (5, -14), (5, -14), (5, -16), (5, -16)] + [(4, -8)] * 10
PATTERNS = ("rand", "extreme", "checker", "checker2", "flat_noise", "ramp", "impulse",
            "vstripes", "hstripes", "max", "zero", "blocks", "grating", "grating",
            "rand_amp", "rand_amp")


# h x w samples of one of the patterns, values 0..mx
def samples(rng, kind, h, w, mx):
    if kind == "rand":
        return rng.integers(0, mx + 1, (h, w))
    if kind == "extreme":
        return rng.integers(0, 2, (h, w)) * mx
    if kind == "checker":
        return ((np.add.outer(np.arange(h), np.arange(w)) & 1) * mx)
    if kind == "checker2":
        return (((np.add.outer(np.arange(h) // 2, np.arange(w) // 2)) & 1) * mx)
    if kind == "flat_noise":
        base = int(rng.integers(0, mx + 1))
        amp = int(rng.choice([1, 2, 4, 16]))
        return np.clip(base + rng.integers(-amp, amp + 1, (h, w)), 0, mx)
    if kind == "ramp":
        a, b = rng.integers(-40, 41, 2)
        return np.clip(mx // 2 + a * np.arange(h)[:, None] + b * np.arange(w)[None, :], 0, mx)
    if kind == "impulse":
        x = np.full((h, w), int(rng.choice([0, mx])))
        m = rng.random((h, w)) < 0.03
        x[m] = mx - x[m]
        return x
    if kind == "vstripes":
        return np.tile((rng.integers(0, 2, w) * mx)[None, :], (h, 1))
    if kind == "hstripes":
        return np.tile((rng.integers(0, 2, h) * mx)[:, None], (1, w))
    if kind == "max":
        return np.full((h, w), mx)
    if kind == "zero":
        return np.zeros((h, w), np.int64)
    if kind == "grating":                  # oriented texture of random strength
        fy, fx = rng.uniform(-0.5, 0.5, 2)
        amp = mx * float(rng.choice([0.01, 0.03, 0.1, 0.3, 0.5]))
        ph = np.add.outer(fy * np.arange(h), fx * np.arange(w))
        return np.clip(np.rint(int(rng.integers(0, mx + 1)) + amp * np.sin(2 * np.pi * ph)), 0, mx).astype(np.int64)
    if kind == "rand_amp":                 # noise of random strength
        amp = int(mx * float(rng.choice([0.02, 0.05, 0.1, 0.25])))
        return np.clip(int(rng.integers(0, mx + 1)) + rng.integers(-amp, amp + 1, (h, w)), 0, mx)
    # blocks: 4x4 blocks of random levels (strong edges on the class grid)
    return np.kron(rng.integers(0, mx + 1, ((h + 3) // 4, (w + 3) // 4)), np.ones((4, 4), np.int64))[:h, :w]


# n Wiener-NS filters: random, at the ends of the ranges, all maximal, all
# minimal, or small
def taps(rng, n):
    t = np.zeros((16, 32), np.int64)
    for c in range(n):
        mode = rng.choice(["rand", "ends", "max", "min", "small"])
        for k, (bits, lo) in enumerate(TAP_RANGE):
            hi = lo + (1 << bits) - 1
            if mode == "rand":
                t[c, k] = rng.integers(lo, hi + 1)
            elif mode == "ends":
                t[c, k] = rng.choice([lo, hi])
            elif mode == "max":
                t[c, k] = hi
            elif mode == "min":
                t[c, k] = lo
            else:
                t[c, k] = rng.integers(-2, 3)
    return t


# one LRSU record in the layout of AVM_LR_DUMP
def write_record(f, rec):
    f.write(b"LRSU")
    f.write(struct.pack("<24i", *(int(rec[k]) for k in HDR_FIELDS)))
    f.write(rec["pu_type"].astype("<i4").tobytes())
    f.write(rec["dgd"].astype("<u2").tobytes())
    f.write(rec["tskip"].astype(np.uint8).tobytes())
    f.write(rec["cls"].astype(np.uint8).tobytes())
    f.write(rec["qval_lut"].astype("<i4").tobytes())
    f.write(rec["taps"].astype("<i2").tobytes())
    f.write(rec["dst"].astype("<u2").tobytes())


def classify(rec):
    """Classes of a stripe, processing unit by processing unit (as the decoder)."""
    cls = np.zeros((rec["mi_rows"], rec["mi_cols"]), np.int64)
    for p in range(rec["n_pu"]):
        x0 = p * PW
        m0, mc = x0 // 4, PW // 4
        pc = dict(rec, bv=3, width=PW, mi_cols=mc, classify_only=0,
                  dgd=rec["dgd"][1:-1, x0:x0 + PW + 2 * BH],
                  tskip=rec["tskip"][:, m0:m0 + mc])
        cls[:, m0:m0 + mc] = pcw_golden.classify(pc)
    return cls


def main(argv):
    opt = {"--set": None, "--pcw": "0.4", "--patterns": None}
    for k in opt:
        if k in argv:
            i = argv.index(k)
            opt[k] = argv[i + 1]
            argv = argv[:i] + argv[i + 2:]
    pats = opt["--patterns"].split(",") if opt["--patterns"] else PATTERNS
    out, n_stripes, seed = argv[0], int(argv[1]), int(argv[2])
    rng = np.random.default_rng(seed)
    luts = {8: [], 10: []}                  # tables of the decoder, by bit depth
    for p in argv[3:]:
        seen = set()
        for r in read_records(p):
            key = r["qval_lut"].tobytes()
            if r["qval_lut"].any() and key not in seen and len(seen) < 4:
                seen.add(key)
                luts[r["bit_depth"]].append((r["qval_lut"], r["base_qindex"]))
    assert luts[8] and luts[10], "need dumps of 8-bit and 10-bit streams"
    st = {"stripes": 0, "units": 0, "pcw": 0, "wns": 0, "none_pu": 0, "samples": 0}
    used_cls = np.zeros(256, bool)
    with open(out, "wb") as f:
        for s in range(n_stripes):
            bd = int(rng.choice([8, 10]))
            mx = (1 << bd) - 1
            h = int(rng.choice([64, 64, 64, 56, 48, 32, 16, 8]))
            widths = [int(rng.choice([64, 64, 128, 192])) for _ in range(int(rng.integers(1, 5)))]
            while sum(widths) > 448:
                widths.pop()
            w = sum(widths)
            # samples of the whole stripe row with its border, in vertical bands
            # of different patterns; rows beyond the saved rows repeat them
            x = np.zeros((h + 2 * BV, w + 2 * BH), np.int64)
            c = 0
            while c < x.shape[1]:
                bw = int(rng.choice([16, 32, 64, 128, x.shape[1]]))
                x[:, c:c + bw] = samples(rng, rng.choice(pats), x.shape[0],
                                         min(bw, x.shape[1] - c), mx)
                c += bw
            x[:BV - 2] = x[BV - 2]
            x[BV + h + 2:] = x[BV + h + 1]
            lut, qidx = luts[bd][int(rng.integers(len(luts[bd])))]
            set_index = int(rng.integers(0, 4)) if opt["--set"] is None else int(opt["--set"])
            tskip_zero = int(rng.random() < 0.3)
            dens = float(rng.choice([0.0, 0.1, 0.5, 1.0]))
            mr = h // 4
            tsk_row = (rng.random((mr, w // 4)) < dens).astype(np.int64)
            x0 = 0
            for wu in widths:
                n_pu = wu // PW
                pcw = rng.random() < float(opt["--pcw"])
                ncls = 1 if pcw else int(rng.choice([1, 2, 3, 4, 6, 8, 12, 16]))
                pu = np.full(n_pu, RESTORE_PC_WIENER if pcw else RESTORE_WIENER_NONSEP, np.int64)
                for i in range(n_pu):
                    if rng.random() < 0.1:
                        pu[i] = RESTORE_NONE
                rec = dict(rtype=RESTORE_PC_WIENER if pcw else RESTORE_WIENER_NONSEP,
                           width=wu, height=h, procunit_width=PW, bit_depth=bd,
                           base_qindex=qidx, qindex_offset=0, set_index=set_index,
                           num_classes=ncls, skip_pcw=0, tskip_zero=tskip_zero,
                           order_hint=s, v_start=64 * (s % 8), h_start=x0, bv=BV, bh=BH,
                           mi_rows=mr, mi_cols=wu // 4, n_pu=n_pu, class_restrict=-1,
                           compute_cls=1, frame_w=4096, frame_h=2176, has_lossless=0,
                           pu_type=pu, dgd=x[:, x0:x0 + wu + 2 * BH],
                           tskip=tsk_row[:, x0 // 4:(x0 + wu) // 4], qval_lut=lut,
                           taps=np.zeros((16, 32), np.int64) if pcw else taps(rng, ncls))
                rec["cls"] = classify(rec)
                rec["dst"] = lr_filter(rec, rec["cls"])
                write_record(f, rec)
                used_cls[np.unique(rec["cls"])] = True
                st["units"] += 1
                st["pcw" if pcw else "wns"] += 1
                st["none_pu"] += int((pu == RESTORE_NONE).sum())
                st["samples"] += h * wu
                x0 += wu
            st["stripes"] += 1
    st["classes"] = int(used_cls.sum())
    print(f"wrote {out}: {st}")


if __name__ == "__main__":
    main(sys.argv[1:])
