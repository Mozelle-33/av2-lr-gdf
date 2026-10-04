#!/usr/bin/env python3
"""Full-width stripe segments for the joint LR/GDF core (VS = 1, PCW = 1, LR = 1)
from the GDF units (AVM_GDF_DUMP) and LR stripes (AVM_LR_DUMP) of one
bitstream.

The GDF units of one stripe of a frame are joined into one segment of type 4
(tools/make_lr_vectors.py) that checks the GDF error and correction, the
PC-Wiener classes (when every restoration unit of the segment has them) and
the final restored samples y = clip(LR + corr).  Restoration unit i of a
segment uses coefficient bank i mod 4: banks 0..3 are loaded before the
segment, and the filter of unit i >= 4 is written into its bank during the
segment (record type 5, tb/tb_gdf.cpp), two strips after the last group of
unit i - 4 has entered, which tests the reloading of banks ahead of use.
With --split X, every stripe is cut at column X into two segments with their
own aprons, as a stripe wider than 4096 columns would be.
With --off <stream.gdfoff> (AVM_GDFOFF_DUMP, the units with GDF off) the
stripes with such units are built as well: their groups carry the side bit
"GDF off" (bit 3 of the group byte, in_gdf = 0), the error and the correction
must be 0 and y the LR output there; --mixed keeps only the stripes with GDF on and off.
With --offstress P every group of a unit with GDF on is switched off with
probability P percent (seeded by the segment number), which moves the on/off
boundaries to arbitrary groups: y is then the LR output of the unit record.
With --lrc <stream.lrcdump> (AVM_LRC_DUMP) a segment whose chroma restoration
units are all in the dump, with at most four filters per plane, becomes a
type-7 record (CH = 1): the chroma of its columns follows (as in
tools/make_lrc_vectors.py --multi; banks per plane in order of appearance;
the units with LR off come from <stream>.lrcoff, AVM_LRCOFF_DUMP)
and U and V are checked as well; --chonly drops the other segments.

Usage: make_wide_vectors.py <out.vec> <stream.gdfdump> <stream.lrdump>
                            [--off <stream.gdfoff>] [--mixed] [--offstress P]
                            [--lrc <stream.lrcdump>] [--chonly]
                            [--split X] [--fip] [--max N] [--only I] [--from I]
"""
import struct
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "analysis"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from gdf_dump import read_records as gdf_records  # noqa: E402
from gdf_golden import Tables, round2signed  # noqa: E402
from gdf_hw_model import FrameParams  # noqa: E402
from lr_golden import RESTORE_NONE, RESTORE_PC_WIENER  # noqa: E402
from lr_golden import read_records as lr_records  # noqa: E402
import make_vectors  # noqa: E402
from make_lr_vectors import coef_table, coef_writes  # noqa: E402
from wide_chroma import read_lrc, wide_chroma  # noqa: E402


def match_lr(g, cands):
    """LR stripe of GDF unit g: same inputs within +-4 and same LR output."""
    h, w, a = g["h"], g["w"], g["apron"]
    j0 = g["j_min"]
    win = g["win"].astype(np.int64)
    for r in cands:
        if not (r["h_start"] <= j0 and j0 + w <= r["h_start"] + r["width"]):
            continue
        x0 = j0 - r["h_start"]
        if (r["height"] == h and
                (r["dgd"][:h + 8, x0:x0 + w + 8] == win[a - 4:a + h + 4, a - 4:a + w + 4]).all() and
                (r["dst"][:, x0:x0 + w] == g["lr"]).all()):
            return r
    return None


def stripes(gpath, lpath, opath=None):
    """Full-width stripes: list of GDF units (left to right) with the LR
    stripe of every unit (None: LR off there); units of opath have GDF off."""
    lrs = {}
    bad_lr = set()
    for r in lr_records(lpath):
        key = (r["order_hint"], r["v_start"])
        if r["has_lossless"] or r["skip_pcw"] or r["class_restrict"] >= 0:
            bad_lr.add(key)
            continue
        lrs.setdefault(key, []).append(r)
    rows = {}
    for g in gdf_records(gpath):
        g["off"] = False
        rows.setdefault((g["frame_idx"], g["i_min"]), []).append(g)
    if opath is not None:
        for g in gdf_records(opath):
            g["off"] = True
            if (g["frame_idx"], g["i_min"]) in rows:   # frames of the main dump
                rows[(g["frame_idx"], g["i_min"])].append(g)
    for (fr, i0), units in rows.items():
        units.sort(key=lambda u: u["j_min"])
        fw = units[0]["frame_w"]
        x = 0
        ok = True
        for u in units:
            if u["has_lossless"] or u["j_min"] != x or u["h"] != units[0]["h"]:
                ok = False
                break
            x = u["j_max"]
        if not ok or x != fw:
            continue
        key = (units[0]["order_hint"], i0)
        if key in bad_lr:
            continue
        lr = []
        for u in units:
            r = match_lr(u, lrs.get(key, []))
            if r is None and not (u["lr"] == u["win"][u["apron"]:u["apron"] + u["h"],
                                                       u["apron"]:u["apron"] + u["w"]]).all():
                ok = False                       # LR output without a matching stripe
                break
            lr.append(r)
        if ok:
            yield units, lr


def write_segment(f, units, lrs, c0, c1, n, T, fps, state, chroma=None):
    """Segment over the stripe columns c0..c1-1 (multiples of 4); chroma: its
    chroma part of wide_chroma (type 7), False: core with CH = 1 but chroma
    LR off, None: no chroma."""
    u0 = units[0]
    h, a, bd = u0["h"], u0["apron"], u0["bit_depth"]
    assert h % 4 == 0
    cyc = h // 2 + 2                           # words per strip (NB = 1)
    fw = u0["frame_w"]
    w = c1 - c0
    # input window rows -2..h+1, columns c0-6..c1+5 (clamped to the frame apron)
    cols = []
    for x in range(c0 - 6, c1 + 6):
        xc = min(max(x, -a), fw + a - 1)
        k = 0
        while k + 1 < len(units) and xc >= units[k]["j_max"]:
            k += 1
        cols.append(units[k]["win"][a - 2:a + h + 2, xc - units[k]["j_min"] + a])
    win = np.stack(cols, axis=1)
    nch = (w + 12 + 3) // 4
    ng = (w + 3) // 4
    buf = np.zeros((h + 4, nch * 4), np.uint16)
    buf[:, :w + 12] = win
    pairs = buf.reshape((h + 4) // 2, 2, nch, 4).transpose(0, 2, 1, 3)

    err = np.concatenate([u["err"] for u in units], axis=1)[:, c0:c1].astype(np.int64)
    out = np.concatenate([u["out"] for u in units], axis=1)[:, c0:c1]
    corr = round2signed(err * u0["scale_val"], 12 - bd)
    goff = np.concatenate([np.full(u["w"], u["off"]) for u in units])[c0:c1]
    if state.get("offstress"):                 # random groups off: y = LR output
        rng = np.random.default_rng(1000 + n)
        soff = np.repeat(rng.random((w + 3) // 4) * 100 < state["offstress"], 4)[:w] & ~goff
        lro = np.concatenate([u["lr"] for u in units], axis=1)[:, c0:c1]
        out = np.where(soff[None, :], lro, out)
        goff = goff | soff
    err[:, goff] = 0                           # GDF off: error and correction 0
    corr[:, goff] = 0

    # restoration units of the segment (distinct LR stripes, left to right)
    rus = []
    for u, r in zip(units, lrs):
        if r is not None and u["j_max"] > c0 and u["j_min"] < c1 and \
                all(r is not q for q in rus):
            rus.append(r)
    rus.sort(key=lambda r: r["h_start"])
    mr, mc = (h + 3) // 4, ng
    tsk = np.zeros((mr, mc), np.uint8)
    cls = np.zeros((mr, mc), np.uint8)
    have_cls = np.zeros(mc, bool)
    lri = np.zeros(ng, np.uint8)
    g_last = {}
    for i, r in enumerate(rus):
        for g in range(ng):
            x = c0 + 4 * g                         # picture column of group g
            if not (r["h_start"] <= x < r["h_start"] + r["width"]):
                continue
            xr = x - r["h_start"]
            on = r["pu_type"][xr // r["procunit_width"]] != RESTORE_NONE
            lri[g] = (4 if on else 0) | (i % 4)
            tsk[:, g] = r["tskip"][:, xr // 4]
            if r["rtype"] == RESTORE_PC_WIENER or r["num_classes"] > 1:
                cls[:, g] = r["cls"][:, xr // 4]
                have_cls[g] = True
            g_last[i] = g
    chk_cls = bool(have_cls.all())
    for g in range(ng):                        # GDF off in the unit of the group
        if goff[min(4 * g, w - 1)]:
            lri[g] |= 8
    state["goff"] += int(goff[::4].sum())
    state["mixed"] += 1 if goff.any() and not goff.all() else 0

    # configuration before the segment: GDF table set, qval rows, banks 0..3, mode
    key = (u0["ref_dst_idx"], u0["qp_idx"])
    wr = []
    if key != state.get("set"):
        fp = fps.get(key) or fps.setdefault(key, FrameParams(T, *key))
        wr += make_vectors.cfg_writes(fp, T, key)
        state["set"] = key
    mode = ((1 if key[0] == 0 else 0) | (1 if bd >= 10 else 0) << 1 |
            (u0["scale_val"] - 1) << 2 | 1 << 5)
    if rus:
        q = next((r for r in rus if r["rtype"] == RESTORE_PC_WIENER or r["num_classes"] > 1), rus[0])
        for t in range(37):
            for fe in range(4):
                v = int(q["qval_lut"][7 * t, fe]) & 0x3FFFFFF
                base = 0x1E00 + (t << 3) + (fe << 1)
                wr += [(base, v & 0xFFFF), (base + 1, v >> 16)]
        for i, r in enumerate(rus[:4]):
            wr += coef_writes(coef_table(r), bank=i)
        mode |= rus[0]["tskip_zero"] << 4 | 1 << 6 | rus[0]["set_index"] << 7
        assert all(r["set_index"] == rus[0]["set_index"] and
                   r["tskip_zero"] == rus[0]["tskip_zero"] for r in rus)
    wr.append((0x1C00, mode))
    if chroma:
        wr += chroma[0]                        # chroma flags and filter banks
    elif chroma is False:
        wr.append((0x1C02, 0))                 # chroma LR off
    f.write(struct.pack("<BI", 1, len(wr)))
    f.write(b"".join(struct.pack("<HH", ad, v) for ad, v in wr))
    # banks of units 4, 5, ... reloaded during the segment: the words of chunk
    # c carry the LR info of group c - 3; two chunks after the last group of
    # unit i - 4, and done before the first group of unit i
    seg_wr = []
    t_free = 0                                 # word index when earlier writes end
    for i in range(4, len(rus)):
        at = (g_last[i - 4] + 3 + 1 + 2) * cyc
        first = max(0, (rus[i]["h_start"] - c0) // 4)
        cw = coef_writes(coef_table(rus[i]), bank=i % 4)
        start = max(at, t_free)
        t_free = start + len(cw)
        assert t_free + 2 * cyc <= (first + 3) * cyc, (i, start, first)
        seg_wr += [(at, ad, v) for ad, v in cw]
    if seg_wr:
        f.write(struct.pack("<BI", 5, len(seg_wr)))
        f.write(b"".join(struct.pack("<IHH", at, ad, v) for at, ad, v in seg_wr))

    flags = 1 | (2 if chk_cls else 0) | 4 | 8
    f.write(struct.pack("<BHHHIHHB", 7 if chroma else 4, h, w, nch, n, mr, mc, flags))
    f.write(pairs.astype("<u2").tobytes())
    exp = np.full((h, ng * 4, 2), make_vectors.DC, np.int8)
    exp[:, :w, 0] = err
    exp[:, :w, 1] = corr
    exp = exp.reshape(h // 2, 2, ng, 4, 2).transpose(0, 2, 1, 3, 4)
    f.write(exp.astype(np.int8).tobytes())
    f.write(np.ascontiguousarray(tsk).tobytes())
    if chk_cls:
        f.write(np.ascontiguousarray(cls).tobytes())
    f.write(np.ascontiguousarray(out).astype("<u2").tobytes())
    f.write(lri.tobytes())
    if chroma:
        f.write(chroma[1])
        state["chroma"] = state.get("chroma", 0) + 1
        state["chroma_samples"] = state.get("chroma_samples", 0) + chroma[2]
        state["chroma_rus"] = state.get("chroma_rus", 0) + chroma[3]
    state["rus"] += len(rus)
    state["reloads"] += max(0, len(rus) - 4)
    state["cls"] += 1 if chk_cls else 0
    state["cols"] = max(state["cols"], w)


def main(argv):
    if "--fip" in argv:
        argv = [x for x in argv if x != "--fip"]
        make_vectors.FIP = True
    split = None
    if "--split" in argv:
        i = argv.index("--split")
        split = int(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
        assert split % 4 == 0
    max_segs = None
    if "--max" in argv:
        i = argv.index("--max")
        max_segs = int(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
    only = None
    if "--only" in argv:                  # write only stripe number I
        i = argv.index("--only")
        only = int(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
    first = 0
    if "--from" in argv:                  # skip the stripes before number I
        i = argv.index("--from")
        first = int(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
    listing = "--list" in argv            # print the restoration units of every stripe
    argv = [a for a in argv if a != "--list"]
    opath = None
    if "--off" in argv:                   # dump of the units with GDF off
        i = argv.index("--off")
        opath = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    mixed = "--mixed" in argv             # only stripes with GDF on and off
    argv = [a for a in argv if a != "--mixed"]
    offstress = 0
    if "--offstress" in argv:             # percentage of groups switched off
        i = argv.index("--offstress")
        offstress = float(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
    lrcs = None
    if "--lrc" in argv:                   # chroma LR dump: type-7 segments
        i = argv.index("--lrc")
        lrcs = read_lrc(argv[i + 1])       # with <stream>.lrcoff beside it
        argv = argv[:i] + argv[i + 2:]
    chonly = "--chonly" in argv           # only segments with their chroma
    argv = [a for a in argv if a != "--chonly"]
    out, gpath, lpath = argv[:3]
    T = Tables()
    fps = {}
    st = {"segs": 0, "stripes": 0, "rus": 0, "reloads": 0, "cls": 0, "cols": 0, "set": None,
          "goff": 0, "mixed": 0, "offstress": offstress}
    with open(out, "wb") as f:
        f.write(b"GDFV" + struct.pack("<I", 1))
        for k, (units, lrs) in enumerate(stripes(gpath, lpath, opath)):
            if mixed and len({u["off"] for u in units}) < 2:
                continue
            if listing:
                seen = []
                for r in lrs:
                    if r is not None and all(r is not q for q in seen):
                        seen.append(r)
                desc = " ".join(("P" if r["rtype"] == RESTORE_PC_WIENER else f"W{r['num_classes']}") +
                                f"/{sum(1 for t in r['pu_type'][:r['n_pu']] if t == RESTORE_NONE)}"
                                for r in seen)
                print(f"stripe {k}: frame {units[0]['frame_idx']} rows {units[0]['i_min']}+{units[0]['h']} "
                      f"units {len(units)} LR-off units {sum(r is None for r in lrs)} "
                      f"GDF-off units {sum(u['off'] for u in units)} RUs: {desc}")
            if (only is not None and k != only) or k < first:
                continue
            fw = units[0]["frame_w"]
            cuts = [0, fw] if split is None or split >= fw else [0, split, fw]
            for c0, c1 in zip(cuts, cuts[1:]):
                ch = None
                if lrcs is not None:
                    ch = wide_chroma(lrcs, units, c0, c1) or False
                    if chonly and not ch:
                        continue
                    if listing and ch:
                        print(f"   columns {c0}..{c1 - 1}: chroma restoration units {ch[3]}")
                write_segment(f, units, lrs, c0, c1, st["segs"], T, fps, st, ch)
                st["segs"] += 1
            st["stripes"] += 1
            if max_segs is not None and st["segs"] >= max_segs:
                break
        f.write(struct.pack("<B", 0))
    del st["set"]
    print(f"wrote {out}: {st}")


if __name__ == "__main__":
    main(sys.argv[1:])
