#!/usr/bin/env python3
"""End-to-end test vectors for the joint LR/GDF core (VS = 1, PCW = 1, LR = 1)
from the GDF units (AVM_GDF_DUMP) and LR stripes (AVM_LR_DUMP) of the same
LR-enabled bitstream.

Each GDF unit becomes one segment record of type 4 (tools/make_lr_vectors.py)
that checks the GDF expected error and correction, the PC-Wiener classes and
the final restored samples y = clip(LR + corr) against the decoder output.
The LR stripe of a unit is the one of the same frame and stripe that covers
its columns; frames are told apart by content, the inputs within +-4 and the
LR output of the unit (order hints repeat in all-intra streams).  Units without a covering LR stripe (restoration unit
RESTORE_NONE, or LR off in the frame) run with LR off.

With --lrc <stream.lrcdump> (AVM_LRC_DUMP of the same bitstream) a unit
whose chroma LR stripe is found becomes a type-7 record: the type-4 record
followed by the chroma of its region (columns i/2.., as in type 6 of
tools/make_lrc_vectors.py), checked as well.  The chroma stripe of a unit is
the one whose down-sampled luma equals the down-sampled input of the unit.

With --off <stream.gdfoff> (AVM_GDFOFF_DUMP) the units with GDF off (block
flag or local mode) follow as segments whose groups carry the side bit "GDF
off" (bit 3 of the group byte, in_gdf = 0): the error and the correction must
be 0 and y the LR output.

Usage: make_joint_vectors.py <out.vec> <stream.gdfdump> <stream.lrdump>
                             [--lrc <stream.lrcdump>] [--off <stream.gdfoff>]
                             [--fip] [--max N]
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
from lrc_dump import records as lrc_records  # noqa: E402
from lrc_golden import downsample  # noqa: E402


def chroma_part(lrcs, g, h, w):
    """Chroma section and configuration writes of a GDF unit (None if its
    chroma LR stripe is not in the dump)."""
    a, i0, j0 = g["apron"], g["i_min"], g["j_min"]
    hh, wc, xc = h // 2, w // 2, j0 // 2
    win = g["win"]
    planes = {}
    for hdr, arr in lrcs.get(i0 // 2, []):
        x0 = xc - hdr["h_start"]
        if hdr["height"] != hh or x0 < 0 or x0 + wc > hdr["width"] or hdr["plane"] in planes:
            continue
        # the down-sampled luma of the unit (rows 0..hh-1, its columns)
        src = win[a:a + h, a:a + w]
        ds = downsample(src, hdr["ds_type"], hh, wc)
        lb = hdr["luma_border"]
        if np.array_equal(ds, arr["luma"][lb:lb + hh, lb + x0:lb + x0 + wc].astype(np.int64)):
            planes[hdr["plane"]] = (hdr, arr, x0)
    if not planes:
        return None
    nch = (w + 12 + 3) // 4
    chroma = np.zeros((2, hh + 4, 2 * nch), np.uint16)
    exp = np.zeros((2, hh, wc), np.uint16)
    side = np.zeros(nch, np.uint8)
    chk = 0
    any_hdr = next(iter(planes.values()))[0]
    for f in (0, 1):
        hdr, arr, x0 = planes.get(1 + f, next(iter(planes.values())))
        bv, bh = hdr["border_v"], hdr["border_h"]
        d = arr["dgd"][bv - 2:bv + hh + 2, :]
        cols = np.clip(x0 + np.arange(-4, 2 * nch - 4) + bh, 0, d.shape[1] - 1)
        chroma[f] = d[:, cols]
        if (1 + f) in planes:
            chk |= 1 << f
            exp[f] = arr["dst"][:, x0:x0 + wc]
            pw = hdr["procunit_width"]
            for c in range(nch):
                x = 2 * c - 4
                if 0 <= x < wc and arr["pu_type"][(x0 + x) // pw] != RESTORE_NONE:
                    side[c] |= 4 << (3 * f)
    top = any_hdr["v_start"] == 0
    bot = any_hdr["v_start"] + hh == any_hdr["frame_h"]
    left = xc == 0
    right = xc + wc == any_hdr["frame_w"]
    ds = any_hdr["ds_type"] if any_hdr["ds_type"] in (0, 1, 2) else 0
    wr = [(0x1C02, 1 | (ds << 1) | (top << 3) | (bot << 4) | (left << 5) | (right << 6))]
    for f in (0, 1):
        if (1 + f) in planes:
            taps = planes[1 + f][1]["taps"]
            wr += [(0x1D00 + (f << 7) + k, int(taps[k]) & 0xFFFF) for k in range(18)]
    data = (struct.pack("<HB", wc, chk) + chroma.astype("<u2").tobytes() +
            side.tobytes() + exp.astype("<u2").tobytes())
    return wr, data, hh * wc * bin(chk).count("1")


def main(argv):
    if "--fip" in argv:                       # class-dependent FIP biases
        argv = [x for x in argv if x != "--fip"]
        make_vectors.FIP = True
    max_segs = None
    if "--max" in argv:
        i = argv.index("--max")
        max_segs = int(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
    lrcs = None
    if "--lrc" in argv:
        i = argv.index("--lrc")
        lrcs = {}
        for kind, hdr, arr in lrc_records(argv[i + 1]):
            if (kind == "LRSC" and hdr["num_classes"] == 1 and hdr["has_luma"]
                    and hdr["has_lossless_segment"] <= 0):
                lrcs.setdefault(hdr["v_start"], []).append((hdr, arr))
        argv = argv[:i] + argv[i + 2:]
    opath = None
    if "--off" in argv:
        i = argv.index("--off")
        opath = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    out, gpath, lpath = argv[:3]

    def units():
        for g in gdf_records(gpath):
            g["off"] = False
            yield g
        if opath is not None:
            for g in gdf_records(opath):
                g["off"] = True
                yield g
    # LR stripes by (order hint, first row)
    lrs = {}
    for r in lr_records(lpath):
        if r["has_lossless"] or r["skip_pcw"] or r["class_restrict"] >= 0:
            continue
        lrs.setdefault((r["order_hint"], r["v_start"]), []).append(r)
    T = Tables()
    fps = {}
    cur_set = last_tab = None
    st = {"segs": 0, "lr_on": 0, "lr_off": 0, "unmatched": 0, "cls": 0, "gdf_off": 0}
    with open(out, "wb") as f:
        f.write(b"GDFV" + struct.pack("<I", 1))
        for g in units():
            if g["has_lossless"]:
                continue
            h, w, a = g["h"], g["w"], g["apron"]
            oh, i0, j0 = g["order_hint"], g["i_min"], g["j_min"]
            win = g["win"].astype(np.int64)
            # the LR stripe of the same frame: same rows and inputs within +-4
            lr = None
            cover = [r for r in lrs.get((oh, i0), [])
                     if r["h_start"] <= j0 and j0 + w <= r["h_start"] + r["width"]]
            for r in cover:
                x0 = j0 - r["h_start"]
                if (r["height"] == h and
                        (r["dgd"][:h + 8, x0:x0 + w + 8] ==
                         win[a - 4:a + h + 4, a - 4:a + w + 4]).all() and
                        (r["dst"][:, x0:x0 + w] == g["lr"]).all()):
                    lr = r                       # same inputs and LR output
                    break
            # no stripe of this frame covers the unit (RESTORE_NONE or LR off
            # in the frame; a covering stripe may belong to another frame of
            # the same order hint): LR output = input
            if lr is None and not (g["lr"] == win[a:a + h, a:a + w]).all():
                st["unmatched"] += 1
                continue
            # GDF configuration of the table set
            key = (g["ref_dst_idx"], g["qp_idx"])
            wr = []
            if key != cur_set:
                fp = fps.get(key) or fps.setdefault(key, FrameParams(T, *key))
                wr += make_vectors.cfg_writes(fp, T, key)
                cur_set = key
            bd = g["bit_depth"]
            # mode word: intra, bit depth, picture scale, GDF on (LR bits below)
            mode = ((1 if key[0] == 0 else 0) | (1 if bd >= 10 else 0) << 1 |
                    (g["scale_val"] - 1) << 2 | 1 << 5)
            mr, mc = (h + 3) // 4, (w + 3) // 4
            tsk = np.zeros((mr, mc), np.uint8)
            cls = None
            if lr is not None:
                x0 = j0 - lr["h_start"]
                pu = x0 // lr["procunit_width"]
                assert x0 % lr["procunit_width"] == 0
                m0 = x0 // 4
                tsk = lr["tskip"][:, m0:m0 + mc]
                if lr["rtype"] == RESTORE_PC_WIENER or lr["num_classes"] > 1:
                    cls = lr["cls"][:, m0:m0 + mc]
                for t in range(37):
                    for fe in range(4):
                        v = int(lr["qval_lut"][7 * t, fe]) & 0x3FFFFFF
                        base = 0x1E00 + (t << 3) + (fe << 1)
                        wr += [(base, v & 0xFFFF), (base + 1, v >> 16)]
                tab = coef_table(lr)
                if last_tab is None or not np.array_equal(tab, last_tab):
                    wr += coef_writes(tab)
                    last_tab = tab
                lr_on = lr["pu_type"][pu] != RESTORE_NONE
                mode |= (lr["tskip_zero"] << 4 | (1 if lr_on else 0) << 6 |
                         lr["set_index"] << 7)
            else:
                lr_on = False
            wr.append((0x1C00, mode))
            cpart = chroma_part(lrcs, g, h, w) if lrcs is not None else None
            if lrcs is not None:
                wr += cpart[0] if cpart else [(0x1C02, 0)]      # chroma LR on / off
            f.write(struct.pack("<BI", 1, len(wr)))
            f.write(b"".join(struct.pack("<HH", ad, v) for ad, v in wr))
            # input window rows -2..h+1, columns -6..w+5 (GDF apron)
            nch = (w + 12 + 3) // 4
            ng = (w + 3) // 4
            buf = np.zeros((h + 4, nch * 4), np.uint16)
            buf[:, :w + 12] = win[a - 2:a + h + 2, :w + 12]
            pairs = buf.reshape((h + 4) // 2, 2, nch, 4).transpose(0, 2, 1, 3)
            flags = 1 | (2 if cls is not None else 0) | 4 | 8
            f.write(struct.pack("<BHHHIHHB", 7 if cpart else 4, h, w, nch, st["segs"], mr, mc, flags))
            f.write(pairs.astype("<u2").tobytes())
            err = g["err"].astype(np.int64)
            corr = round2signed(err * g["scale_val"], 12 - bd)
            exp = np.full((h, ng * 4, 2), make_vectors.DC, np.int8)
            exp[:, :w, 0] = 0 if g["off"] else err      # GDF off: error and correction 0
            exp[:, :w, 1] = 0 if g["off"] else corr
            exp = exp.reshape(h // 2, 2, ng, 4, 2).transpose(0, 2, 1, 3, 4)
            f.write(exp.astype(np.int8).tobytes())
            f.write(np.ascontiguousarray(tsk).astype(np.uint8).tobytes())
            if cls is not None:
                f.write(np.ascontiguousarray(cls).astype(np.uint8).tobytes())
                st["cls"] += 1
            f.write(np.ascontiguousarray(g["out"]).astype("<u2").tobytes())
            f.write(bytes([12 if g["off"] else 4] * ng))   # per group: GDF off, LR on, bank 0
            st["gdf_off"] += 1 if g["off"] else 0
            if cpart:
                f.write(cpart[1])
                st["chroma"] = st.get("chroma", 0) + 1
                st["chroma_samples"] = st.get("chroma_samples", 0) + cpart[2]
            st["segs"] += 1
            st["lr_on" if lr_on else "lr_off"] += 1
            if max_segs is not None and st["segs"] >= max_segs:
                break
        f.write(struct.pack("<B", 0))
    print(f"wrote {out}: {st}")


if __name__ == "__main__":
    main(sys.argv[1:])
