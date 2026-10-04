"""Build the ROM images for the on-board self-test (rtl/gdf_selftest.v).

Usage:
  python3 make_rom.py <outdir> --dumps <dump files...> [--stress <stress.bin>]
                      [--in-budget WORDS] [--sets N] [--units N] [--stress-units N]

Test content (in this order, grouped by table set):
  * full-width stripes assembled from consecutive 64x64 units of the AVM dumps
    (only stripes whose units are all present and overlap consistently);
  * single 64-wide units from the dumps (short rows, many pass boundaries);
  * stripe-mode stress units from tools/gdf_unit_harness (extreme content).

Outputs:
  cmd.hex  (32 bit)  01|addr[29:17]|data[15:0]         config write
                     10|H[29:23]|NCH[22:12]|LASTV[11:10] segment header,
                        followed by one word: expected CRC-32 of the outputs
                     11                                 end of stream
  in.hex   (80 bit)  input chunks, consumed in order
  rom_params.vh      depths / address widths
  manifest.json      segments, expected CRCs, predicted cycles

Output signature per segment: CRC-32/MPEG-2 (poly 04C11DB7, init FFFFFFFF, no
reflection, no final xor) over one 112-bit word per output group, fed MSB
first: word = corr[55:0] << 56 | err[55:0], sample s = row*4+col at [7s+:7];
samples in columns >= W are zero.
"""
import argparse
import collections
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "analysis"))
from gdf_dump import read_records  # noqa: E402
from gdf_golden import Tables, round2signed  # noqa: E402
from gdf_hw_model import FrameParams  # noqa: E402
import make_vectors as mv  # noqa: E402

NTOK = 24          # gdf_core pipeline tokens (proposed datapath)
VS = False         # --vs: column-major core (chunk-major input, column output)


def clog2(n):
    return max(1, (int(n) - 1).bit_length())


# ---------------------------------------------------------------- CRC-32/MPEG-2
_T = []
for i in range(256):
    c = i << 24
    for _ in range(8):
        c = ((c << 1) ^ 0x04C11DB7) if c & 0x80000000 else (c << 1)
    _T.append(c & 0xFFFFFFFF)


def crc32_mpeg2(data, crc=0xFFFFFFFF):
    for b in data:
        crc = ((crc << 8) & 0xFFFFFFFF) ^ _T[((crc >> 24) ^ b) & 0xFF]
    return crc


# ---------------------------------------------------------------- segments
class Seg:
    """One core segment: H x W samples, window rows -2..H+1, cols -6..W+5."""

    def __init__(self, kind, key, bd, scale, win, err, tag):
        self.kind, self.key, self.bd, self.scale, self.tag = kind, key, bd, scale, tag
        self.h = err.shape[0]
        self.w = err.shape[1]
        self.win = win            # (h+4) x (w+12)
        self.err = err
        self.nch = (self.w + 12 + 3) // 4
        self.ng = (self.w + 3) // 4
        self.words = (self.h // 2 + 2) * self.nch

    def mode(self):
        return (1 if self.key[0] == 0 else 0) | ((1 if self.bd >= 10 else 0) << 1) \
            | ((self.scale - 1) << 2)

    def in_words(self):
        buf = np.zeros((self.h + 4, self.nch * 4), np.int64)
        buf[:, :self.w + 12] = self.win
        order = [(pr, c) for pr in range(self.h // 2 + 2) for c in range(self.nch)]
        if VS:      # column-major core: chunk-major word order
            order = [(pr, c) for c in range(self.nch) for pr in range(self.h // 2 + 2)]
        out = []
        for pr, c in order:
            s = list(buf[2 * pr, 4 * c:4 * c + 4]) + list(buf[2 * pr + 1, 4 * c:4 * c + 4])
            word = 0
            for i, v in enumerate(s):
                word |= (int(v) & 0x3FF) << (10 * i)
            out.append(word)
        return out

    def crc(self):
        err = self.err.astype(np.int64)
        corr = round2signed(err * self.scale, 12 - self.bd)
        e = np.zeros((self.h, self.ng * 4), np.int64)
        c = np.zeros((self.h, self.ng * 4), np.int64)
        e[:, :self.w] = err & 0x7F
        c[:, :self.w] = corr & 0x7F
        data = bytearray()
        order = [(b, g) for b in range(self.h // 2) for g in range(self.ng)]
        if VS:      # column-major core: groups leave column by column
            order = [(b, g) for g in range(self.ng) for b in range(self.h // 2)]
        for b, g in order:
            word = 0
            for r in range(2):
                for cc in range(4):
                    s = r * 4 + cc
                    word |= int(e[2 * b + r, 4 * g + cc]) << (7 * s)
                    word |= int(c[2 * b + r, 4 * g + cc]) << (56 + 7 * s)
            data += word.to_bytes(14, "big")
        return crc32_mpeg2(data)

    def cycles(self):
        return (self.h // 2 + (2 if VS else 4)) * self.nch


def unit_seg(rec, kind, tag):
    h, w, ap = rec["h"], rec["w"], rec["apron"]
    win = rec["win"][ap - 2:ap + h + 2, :w + 12].astype(np.int64)
    return Seg(kind, (rec["ref_dst_idx"], rec["qp_idx"]), rec["bit_depth"],
               rec["scale_val"], win, rec["err"].astype(np.int64), tag)


def stripe_seg(units, tag):
    """Concatenate the units of one stripe (sorted by j_min); None if not valid."""
    u0 = units[0]
    fw = u0["frame_w"]
    if u0["j_min"] != 0 or units[-1]["j_max"] != fw:
        return None
    for a, b in zip(units, units[1:]):
        if a["j_max"] != b["j_min"]:
            return None
        ap = a["apron"]
        # a's right apron and last own columns must equal b's first columns
        if not (np.array_equal(a["win"][:, ap + a["w"]:], b["win"][:, ap:2 * ap]) and
                np.array_equal(a["win"][:, a["w"]:ap + a["w"]], b["win"][:, :ap])):
            return None
    for u in units:
        if (u["ref_dst_idx"], u["qp_idx"], u["bit_depth"], u["scale_val"], u["i_min"],
                u["i_max"], u["apron"]) != (u0["ref_dst_idx"], u0["qp_idx"], u0["bit_depth"],
                                            u0["scale_val"], u0["i_min"], u0["i_max"], u0["apron"]):
            return None
    h, ap = u0["h"], u0["apron"]
    cols = [u0["win"][ap - 2:ap + h + 2, :ap]]
    for u in units:
        cols.append(u["win"][ap - 2:ap + h + 2, ap:ap + u["w"]])
    ul = units[-1]
    cols.append(ul["win"][ap - 2:ap + h + 2, ap + ul["w"]:ap + ul["w"] + 6])
    win = np.concatenate(cols, axis=1).astype(np.int64)
    err = np.concatenate([u["err"] for u in units], axis=1).astype(np.int64)
    return Seg("stripe", (u0["ref_dst_idx"], u0["qp_idx"]), u0["bit_depth"],
               u0["scale_val"], win, err, tag)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("outdir")
    ap.add_argument("--dumps", nargs="+", required=True)
    ap.add_argument("--stress")
    ap.add_argument("--in-budget", type=int, default=128000)
    ap.add_argument("--sets", type=int, default=9)
    ap.add_argument("--units", type=int, default=32)
    ap.add_argument("--stress-units", type=int, default=24)
    ap.add_argument("--fip", action="store_true", help="configuration for the FIP datapath")
    ap.add_argument("--vs", action="store_true", help="column-major core (VS = 1)")
    a = ap.parse_args()
    mv.FIP = a.fip
    global VS
    VS = a.vs
    out = Path(a.outdir)
    out.mkdir(parents=True, exist_ok=True)

    # ---- candidate stripes (one per signature, tallest kept) and a unit sample
    def sig(s):
        return (s.w, s.key, s.bd, s.scale)
    by_sig, units = {}, []
    for p in a.dumps:
        name = Path(p).stem
        groups = collections.defaultdict(list)
        for rec in read_records(p):
            if rec["has_lossless"]:
                continue
            groups[(rec["frame_idx"], rec["i_min"], rec["i_max"])].append(rec)
        n_ok = 0
        for (fr, i0, i1), us in groups.items():
            us.sort(key=lambda r: r["j_min"])
            k = (us[0]["frame_w"], (us[0]["ref_dst_idx"], us[0]["qp_idx"]),
                 us[0]["bit_depth"], us[0]["scale_val"])
            old = by_sig.get(k)
            if old is None or old.h < us[0]["h"]:
                s = stripe_seg(us, f"{name}/f{fr}/r{i0}")
                if s is not None:
                    by_sig[k] = s
                    n_ok += 1
        allu = [(name, fr, u) for (fr, _, _), us in groups.items() for u in us]
        keep = ("h", "w", "apron", "ref_dst_idx", "qp_idx", "bit_depth", "scale_val",
                "i_min", "j_min")
        units += [(n, f, {**{k: u[k] for k in keep}, "win": u["win"].copy(),
                          "err": u["err"].copy()})
                  for n, f, u in allu[::max(1, len(allu) // 6)][:6]]
        del groups, allu
        print(f"{name}: {n_ok} new stripe signatures", file=sys.stderr)
    # ---- stripes: round-robin over (width, intra/inter, bit depth) buckets,
    #      at most a.sets table sets in total
    buckets = collections.defaultdict(list)
    for s in sorted(by_sig.values(), key=lambda s: (s.key, s.scale)):
        buckets[(s.w, s.key[0] > 0, s.bd)].append(s)
    print("stripe buckets:", {k: len(v) for k, v in sorted(buckets.items())}, file=sys.stderr)
    keys, chosen, used = [], [], 0
    budget_stripes = int(a.in_budget * 0.72)
    progress = True
    while progress:
        progress = False
        for bk in sorted(buckets, key=lambda k: (-k[0], k[1], k[2])):
            lst = buckets[bk]
            while lst:
                s = lst.pop(0)
                if s.key not in keys and len(keys) >= a.sets:
                    continue
                if used + s.words > budget_stripes:
                    continue
                if s.key not in keys:
                    keys.append(s.key)
                chosen.append(s)
                used += s.words
                progress = True
                break
    # 64-wide units from the chosen sets (spread over files / frames)
    ucands = [u for u in units if (u[2]["ref_dst_idx"], u[2]["qp_idx"]) in keys]
    step = max(1, len(ucands) // max(1, a.units))
    for name, fr, rec in ucands[::step][:a.units]:
        s = unit_seg(rec, "unit", f"{name}/f{fr}/r{rec['i_min']}c{rec['j_min']}")
        chosen.append(s)
        used += s.words
    # stress units (stripe mode) from the chosen sets
    if a.stress:
        n = 0
        for rec in read_records(a.stress):
            if (rec["ref_dst_idx"], rec["qp_idx"]) not in keys or rec["has_lossless"]:
                continue
            if n >= a.stress_units or used + 646 > a.in_budget:
                break
            s = unit_seg(rec, "stress", f"stress{n}")
            chosen.append(s)
            used += s.words
            n += 1

    # ---- emit, grouped by table set
    T = Tables()
    cmd, inw, man = [], [], []
    for key in keys:
        segs = [s for s in chosen if s.key == key]
        if not segs:
            continue
        fp = FrameParams(T, *key)
        for ad, d in mv.cfg_writes(fp, T, key):
            cmd.append((1 << 30) | (ad << 17) | (d & 0xFFFF))
        for s in segs:
            cmd.append((1 << 30) | (0x1C00 << 17) | s.mode())
            lastv = (s.w - 1) % 4
            cmd.append((2 << 30) | (s.h << 23) | (s.nch << 12) | (lastv << 10))
            crc = s.crc()
            cmd.append(crc)
            base = len(inw)
            inw += s.in_words()
            man.append(dict(kind=s.kind, tag=s.tag, set=list(key), bd=s.bd, scale=s.scale,
                            h=s.h, w=s.w, nch=s.nch, groups=(s.h // 2) * s.ng,
                            in_base=base, words=s.words, crc=f"{crc:08x}",
                            cycles=s.cycles()))
    cmd.append(3 << 30)

    (out / "cmd.hex").write_text("".join(f"{x:08x}\n" for x in cmd))
    (out / "in.hex").write_text("".join(f"{x:020x}\n" for x in inw))
    # banks of 4096 words for the banked ROM streamer: rom_<tag>_<bb>.hex
    for old in out.glob("rom_*_*.hex"):
        old.unlink()
    for tag, words, digits in (("cm", cmd, 8), ("in", inw, 20)):
        for b in range((len(words) + 4095) // 4096):
            chunk = words[b * 4096:(b + 1) * 4096]
            (out / f"rom_{tag}_{b:02d}.hex").write_text("".join(f"{x:0{digits}x}\n" for x in chunk))
    params = dict(CMD_N=len(cmd), CMD_AW=max(13, clog2(len(cmd))), CMD_NB=(len(cmd) + 4095) // 4096,
                  IN_N=len(inw), IN_AW=max(13, clog2(len(inw))), IN_NB=(len(inw) + 4095) // 4096)
    (out / "rom_params.vh").write_text("".join(f"localparam {k} = {v};\n" for k, v in params.items()))
    summ = dict(segments=len(man),
                by_kind={k: sum(1 for m in man if m["kind"] == k) for k in ("stripe", "unit", "stress")},
                sets=[list(k) for k in keys], samples=sum(m["h"] * m["w"] for m in man),
                groups=sum(m["groups"] for m in man), pass_cycles=sum(m["cycles"] for m in man),
                cmd_words=len(cmd), in_words=len(inw), params=params)
    (out / "manifest.json").write_text(json.dumps(dict(summary=summ, segments=man), indent=1))
    print(json.dumps(summ, indent=1))


if __name__ == "__main__":
    main()
