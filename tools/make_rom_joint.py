#!/usr/bin/env python3
"""Build the ROM images of the on-board self-test (rtl/gdf_selftest.v) for the
joint LR/GDF core (LR = 1, column scan) from joint vector files
(tools/make_joint_vectors.py, tools/make_lr_vectors.py).

Usage: make_rom_joint.py <outdir> <file.vec> [...] [--max-words N]

Configuration records become config-write commands; every segment record
(type 4) becomes a segment header with its signature flags, the expected
CRC-32/MPEG-2 of its outputs and its input words; writes during a segment
(record type 5, tools/make_wide_vectors.py) follow its CRC word as groups
00|n|at of n writes issued once `at` input words have been accepted:
  cmd  (32 bit): 01|addr|data, 10|H|NCH|LASTV|CLS[9]|GDF[8] + CRC,
                 00|n[29:16]|at[15:0] + n x 01|addr|data, 11 = end
  in   (85 bit): GDF off [84] | LR info {on, bank} [83:81] | transform-skip
                 flag [80] | 2 x 4 samples [79:0], chunk-major
Signature word per output group (groups column by column, bands top to
bottom), 200 bit, fed MSB first: y[79:0] << 120 | class << 112 (odd bands,
CLS) | corr[55:0] << 56 | err[55:0] (GDF); samples in columns >= W are zero.

--ch (core with the chroma LR, CH = 1): 171-bit input words with the chroma
word of the luma word (main row [123:84], extra row [163:124]), the side
info of its strip [169:164] and GDF off [170] (instead of [84]) (tools/make_joint_vectors.py --lrc, type 7, and
tools/make_lrc_vectors.py, type 6); header bits CHK_U[7], CHK_V[6], NOY[5]
(type 6: luma not signed) and two CRC words, luma and chroma.  Chroma
signature: one 64-bit word {row << 51 | strip << 40 | V1, V0, U1, U0} per
output in the order of the core (pass c: rows H/2-2, H/2-1 of strip c-2
for c >= 4, then rows 0..H/2-3 of strip c-1 for c >= 3; after the last
pass rows H/2-2, H/2-1 of strip NCH-2), the unchecked planes zero.  Type-4
segments run with the chroma off (0x1C02 = 0).
"""
import json
import struct
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from make_rom import clog2, crc32_mpeg2  # noqa: E402


def read_vec(path):
    """Yield ('cfg', [(addr, data)]) and ('seg', dict) records."""
    f = open(path, "rb")
    assert f.read(4) == b"GDFV"
    f.read(4)
    while True:
        t = f.read(1)
        if not t or t[0] == 0:
            return
        if t[0] == 1:
            (n,) = struct.unpack("<I", f.read(4))
            yield "cfg", list(struct.iter_unpack("<HH", f.read(4 * n)))
        elif t[0] == 5:
            (n,) = struct.unpack("<I", f.read(4))
            yield "segwr", list(struct.iter_unpack("<IHH", f.read(8 * n)))
        elif t[0] in (4, 7):
            h, w, nch, sid, mr, mc, fl = struct.unpack("<HHHIHHB", f.read(15))
            npairs, ng = (h + 4) // 2, (w + 3) // 4
            inp = np.frombuffer(f.read(2 * npairs * nch * 8), "<u2").reshape(npairs, nch, 8)
            exp = (np.frombuffer(f.read(h // 2 * ng * 16), np.int8).reshape(h // 2, ng, 8, 2)
                   if fl & 1 else None)
            tsk = np.frombuffer(f.read(mr * mc), np.uint8).reshape(mr, mc)
            cls = np.frombuffer(f.read(mr * mc), np.uint8).reshape(mr, mc) if fl & 2 else None
            y = np.frombuffer(f.read(2 * h * w), "<u2").reshape(h, w) if fl & 4 else None
            lri = (np.frombuffer(f.read(ng), np.uint8) if fl & 8
                   else np.full(ng, 4, np.uint8))
            s = dict(h=h, w=w, nch=nch, id=sid, mr=mr, mc=mc, flags=fl, inp=inp,
                     exp=exp, tsk=tsk, cls=cls, y=y, lri=lri, chroma=None)
            if t[0] == 7:
                s["chroma"] = read_chroma(f, h, nch)
            yield "seg", s
        elif t[0] == 6:                 # chroma-only segment (make_lrc_vectors.py)
            h, w, nch, sid, wc, chk = struct.unpack("<HHHIHB", f.read(13))
            npairs = (h + 4) // 2
            inp = np.frombuffer(f.read(2 * npairs * nch * 8), "<u2").reshape(npairs, nch, 8)
            c = read_chroma_body(f, h, nch, wc, chk)
            yield "seg", dict(h=h, w=w, nch=nch, id=sid, mr=0, mc=0, flags=0, inp=inp,
                              exp=None, tsk=np.zeros((0, 0), np.uint8), cls=None, y=None,
                              lri=np.zeros((w + 3) // 4, np.uint8), chroma=c)
        else:
            raise ValueError(f"unsupported record {t[0]} in {path}")


def read_chroma_body(f, h, nch, wc, chk):
    """Chroma rows -2..H/2+1 of columns -4..2NCH-5 (U, V), side info per strip,
    expected U, V (rows 0..H/2-1, columns 0..WC-1)."""
    hh = h // 2
    chroma = np.frombuffer(f.read(2 * 2 * (hh + 4) * 2 * nch), "<u2").reshape(2, hh + 4, 2 * nch)
    side = np.frombuffer(f.read(nch), np.uint8)
    cexp = np.frombuffer(f.read(2 * 2 * hh * wc), "<u2").reshape(2, hh, wc)
    return dict(wc=wc, chk=chk, data=chroma, side=side, exp=cexp)


def read_chroma(f, h, nch):
    wc, chk = struct.unpack("<HB", f.read(3))
    return read_chroma_body(f, h, nch, wc, chk)


def seg_words(s, ch=False):
    """85-bit input words, chunk-major, pairs 0..H/2+1 per chunk: GDF off
    [84] and LR info [83:81] of group c-3, transform-skip flag [80], samples
    [79:0]; with ch the chroma word [163:84], the chroma side info of the
    strip [169:164] and GDF off at [170]."""
    out = []
    ng = len(s["lri"])
    hh = s["h"] // 2
    cr = s["chroma"]

    def cs(pl, row, col):                # chroma sample, row -2.., column -4..
        return int(cr["data"][pl, row + 2, col + 4]) & 0x3FF

    def crow(row, c):                    # {V1, V0, U1, U0} of strip c
        return (cs(0, row, 2 * c - 4) | cs(0, row, 2 * c - 3) << 10 |
                cs(1, row, 2 * c - 4) << 20 | cs(1, row, 2 * c - 3) << 30)

    for c in range(s["nch"]):
        lr = int(s["lri"][c - 3]) if 0 <= c - 3 < ng else 0
        for p in range(hh + 2):
            word = (lr & 7) << 81 | (lr >> 3 & 1) << (170 if ch else 84)
            for i, v in enumerate(s["inp"][p, c]):
                word |= (int(v) & 0x3FF) << (10 * i)
            m, mcol = (p - 1) // 2, c - 2
            if (p & 1) and m < s["mr"] and 0 <= mcol < s["mc"]:
                word |= int(s["tsk"][m, mcol]) << 80
            if ch and cr is not None:
                main = crow(p - 1, c)
                extra = crow(-2, c) if p == 0 else crow(hh + 1, c) if p == hh + 1 else 0
                word |= (main | extra << 40) << 84
                word |= int(cr["side"][c]) << 164
            out.append(word)
    return out


def seg_crc_c(s):
    """Chroma signature in the output order of the core (see the module doc)."""
    cr = s["chroma"]
    if cr is None:
        return 0xFFFFFFFF
    hh, nch, wc, chk = s["h"] // 2, s["nch"], cr["wc"], cr["chk"]
    assert s["w"] % 4 == 0 and wc == s["w"] // 2, "chroma segments need W % 4 == 0"
    # (strip, row) of every chroma output in the order of the core
    order = []
    for c in range(nch):
        if c >= 4:
            order += [(c - 2, hh - 2), (c - 2, hh - 1)]
        if c >= 3:
            order += [(c - 1, r) for r in range(hh - 2)]
    if nch - 1 >= 3:
        order += [(nch - 2, hh - 2), (nch - 2, hh - 1)]
    data = bytearray()
    for st, r in order:
        y = 0
        for pl in range(2):
            if (chk >> pl) & 1:
                for j in range(2):
                    x = 2 * st - 4 + j
                    assert 0 <= x < wc
                    y |= int(cr["exp"][pl, r, x]) << (20 * pl + 10 * j)
        data += ((r << 51) | (st << 40) | y).to_bytes(8, "big")
    return crc32_mpeg2(data)


def seg_crc(s):
    h, w = s["h"], s["w"]
    ng = (w + 3) // 4
    data = bytearray()
    for g in range(ng):
        for b in range(h // 2):
            word = 0
            for r in range(2):
                for cc in range(4):
                    sm, row, col = r * 4 + cc, 2 * b + r, 4 * g + cc
                    if col >= w:
                        continue
                    if s["flags"] & 1:
                        e, cr = s["exp"][b, g, sm]
                        word |= (int(e) & 0x7F) << (7 * sm)
                        word |= (int(cr) & 0x7F) << (56 + 7 * sm)
                    word |= int(s["y"][row, col]) << (120 + 10 * sm)
            if (s["flags"] & 2) and (b & 1):
                word |= int(s["cls"][b >> 1, g]) << 112
            data += word.to_bytes(25, "big")
    return crc32_mpeg2(data)


def main(argv):
    max_words = None
    ch = "--ch" in argv
    argv = [a for a in argv if a != "--ch"]
    if "--max-words" in argv:
        i = argv.index("--max-words")
        max_words = int(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
    out = Path(argv[0])
    out.mkdir(parents=True, exist_ok=True)
    cmd, inw, man = [], [], []
    pend = []
    segwr = []
    for path in argv[1:]:
        for kind, rec in read_vec(path):
            if kind == "cfg":
                pend += rec
                continue
            if kind == "segwr":
                segwr += rec
                continue
            s = rec
            noy = s["y"] is None                 # chroma-only segment
            assert ch or not noy, "chroma segments need --ch"
            assert noy or s["flags"] & 4, "segments must carry the restored samples"
            assert s["chroma"] is None or ch, "chroma records need --ch"
            words = seg_words(s, ch)
            if max_words is not None and len(inw) + len(words) > max_words:
                break
            if ch and s["chroma"] is None and not any(ad == 0x1C02 for ad, _ in pend):
                pend.append((0x1C02, 0))         # chroma off
            for ad, d in pend:
                cmd.append((1 << 30) | (ad << 17) | (d & 0xFFFF))
            pend = []
            lastv = (s["w"] - 1) % 4
            fl = (1 if s["flags"] & 2 else 0) << 9 | (1 if s["flags"] & 1 else 0) << 8
            if ch:
                chk = s["chroma"]["chk"] if s["chroma"] is not None else 0
                fl |= (chk & 1) << 7 | (chk >> 1 & 1) << 6 | (1 if noy else 0) << 5
            cmd.append((2 << 30) | (s["h"] << 23) | (s["nch"] << 12) | (lastv << 10) | fl)
            crc = 0xFFFFFFFF if noy else seg_crc(s)
            cmd.append(crc)
            crc_c = seg_crc_c(s) if ch else None
            if ch:
                cmd.append(crc_c)
            # writes during the segment: groups of equal trigger word index
            # in-segment writes: one group per trigger word index
            i = 0
            while i < len(segwr):
                at = segwr[i][0]
                j = i
                while j < len(segwr) and segwr[j][0] == at:
                    j += 1
                assert at < len(words) and j - i < (1 << 14)
                cmd.append((0 << 30) | ((j - i) << 16) | at)
                cmd += [(1 << 30) | (ad << 17) | (d & 0xFFFF) for _, ad, d in segwr[i:j]]
                i = j
            man.append(dict(file=Path(path).name, id=s["id"], h=s["h"], w=s["w"],
                            nch=s["nch"], flags=s["flags"], in_base=len(inw),
                            words=len(words), crc=f"{crc:08x}", seg_writes=len(segwr),
                            crc_c=(f"{crc_c:08x}" if ch else None),
                            chroma_samples=(0 if s["chroma"] is None else
                                            s["h"] // 2 * s["chroma"]["wc"] * bin(s["chroma"]["chk"]).count("1"))))
            segwr = []
            inw += words
    cmd.append(3 << 30)
    for old in out.glob("rom_*_*.hex"):
        old.unlink()
    # ROM images in blocks of 4096 words (one hex file per block)
    for tag, words, digits in (("cm", cmd, 8), ("in", inw, 43 if ch else 22)):
        for b in range((len(words) + 4095) // 4096):
            chunk = words[b * 4096:(b + 1) * 4096]
            (out / f"rom_{tag}_{b:02d}.hex").write_text(
                "".join(f"{x:0{digits}x}\n" for x in chunk))
    params = dict(CMD_N=len(cmd), CMD_AW=max(13, clog2(len(cmd))), CMD_NB=(len(cmd) + 4095) // 4096,
                  IN_N=len(inw), IN_AW=max(13, clog2(len(inw))), IN_NB=(len(inw) + 4095) // 4096)
    (out / "rom_params.vh").write_text("".join(f"localparam {k} = {v};\n" for k, v in params.items()))
    summ = dict(segments=len(man), samples=sum(m["h"] * m["w"] for m in man),
                chroma_samples=sum(m["chroma_samples"] for m in man),
                cmd_words=len(cmd), in_words=len(inw), params=params)
    (out / "manifest.json").write_text(json.dumps(dict(summary=summ, segments=man), indent=1))
    print(json.dumps(summ))


if __name__ == "__main__":
    main(sys.argv[1:])
