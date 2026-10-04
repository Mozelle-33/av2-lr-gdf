"""Generate RTL test vectors for gdf_core from GDF dumps / stress vectors.

Usage: python3 make_vectors.py <out.vec> <dump1> [dump2 ...] [--max N]

File format (little endian):
  "GDFV" u32 version(=1)
  records:
    u8 1  CFG : u32 n, n x (u16 addr, u16 data)
    u8 2  SEG : u16 H, u16 W, u16 NCH, u32 id,
                (H+4)/2 pairs x NCH chunks x 8 x u16 raw samples
                  (upper row samples 0..3, then lower row samples 0..3),
                H/2 bands x NG groups x 8 x (i8 err, i8 corr), NG = ceil(W/4)
                  (columns >= W carry 0x7F = don't care)
    u8 0  END
"""
import struct
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "analysis"))
from gdf_dump import read_records  # noqa: E402
from gdf_golden import Tables, round2signed  # noqa: E402
from gdf_hw_model import FrameParams, H_FEATS, M_FEATS, V_FEATS  # noqa: E402

DC = 0x7F


MAC_FULL = False   # --full / --mac-full: 66-slot weights (MACF=1 datapath)
IDX_FULL = False   # --full / --idx-full: natural table layout (IDXF=1 datapath)
FIP = False        # --fip: class-dependent biases of the fast-inner-product datapath


def cfg_writes(fp, T=None, key=None):
    """Configuration writes for one (refDst, qp) table set."""
    wr = []
    for c in range(4):
        if MAC_FULL:
            r, q = key
            slots = [T.W[r, q, o, k, c] for o in range(3) for k in range(22)]
            assert len(slots) == 66
        else:
            slots = list(fp.wv[c]) + list(fp.wh[c]) + list(fp.wm[c])
            assert len(slots) == 34
        for s, v in enumerate(slots):
            wr.append((0x1000 + (c << 7) + s, int(v) & 0x3FF))
        for k in range(22):
            wr.append((0x1400 + (c << 5) + k, int(fp.alpha[k][c]) & 0x1FF))
    if FIP:
        # fast inner product: class-dependent biases b_o - K, where K is the sum
        # of w_a * w_b over the pairs of the sub-filter feeding output o
        pv = [(5, 9), (16, 17), (8, 10), (0, 1), (2, 3), (4, 6)]
        ph = [(5, 9), (16, 17), (8, 10), (7, 11), (12, 13), (14, 15)]
        pm = [(5, 9), (16, 17), (3, 15)]
        for c in range(4):
            kv = sum(int(fp.wv[c][V_FEATS.index(a)]) * int(fp.wv[c][V_FEATS.index(b)]) for a, b in pv)
            kh = sum(int(fp.wh[c][H_FEATS.index(a)]) * int(fp.wh[c][H_FEATS.index(b)]) for a, b in ph)
            km = sum(int(fp.wm[c][M_FEATS.index(a)]) * int(fp.wm[c][M_FEATS.index(b)]) for a, b in pm)
            odd = c & 1
            bias = (int(fp.bias[0]) - (kh if odd else kv),
                    int(fp.bias[1]) - (kv if odd else kh),
                    int(fp.bias[2]) - km)
            for o, bv in enumerate(bias):
                assert -(1 << 21) <= bv < (1 << 21)
                u = bv & 0x3FFFFF
                wr.append((0x1800 + (c << 3) + (o << 1), u & 0xFFFF))
                wr.append((0x1800 + (c << 3) + (o << 1) + 1, u >> 16))
    else:
        for i in range(3):
            wr.append((0x1800 + i, int(fp.bias[i]) & 0xFFFF))
    if IDX_FULL:  # natural table layout, address computed with multipliers
        r, q = key
        lut = np.zeros(4096, np.int64)
        if r == 0:
            lut[:] = T.E_intra[q]
        else:
            lut[:1000] = T.E_inter[r - 1][q]
    else:
        lut = fp.lut
    for a in range(4096):
        wr.append((a, int(lut[a]) & 0x7F))
    return wr


def main(out, paths, max_units=None):
    T = Tables()
    fps = {}
    cur_set = None
    n_units = 0
    with open(out, "wb") as f:
        f.write(b"GDFV" + struct.pack("<I", 1))
        for p in paths:
            for rec in read_records(p):
                if rec["has_lossless"]:
                    continue
                if max_units is not None and n_units >= max_units:
                    break
                key = (rec["ref_dst_idx"], rec["qp_idx"])
                if key != cur_set:
                    fp = fps.get(key) or fps.setdefault(key, FrameParams(T, *key))
                    wr = cfg_writes(fp, T, key)
                    f.write(struct.pack("<BI", 1, len(wr)))
                    f.write(b"".join(struct.pack("<HH", a, d) for a, d in wr))
                    cur_set = key
                bd = rec["bit_depth"]
                mode = (1 if key[0] == 0 else 0) | ((1 if bd >= 10 else 0) << 1) \
                    | ((rec["scale_val"] - 1) << 2)
                f.write(struct.pack("<BI", 1, 1) + struct.pack("<HH", 0x1C00, mode))

                h, w, a = rec["h"], rec["w"], rec["apron"]
                win = rec["win"].astype(np.uint16)
                nch = (w + 12 + 3) // 4
                ng = (w + 3) // 4
                cols = nch * 4
                rows = win[a - 2:a + h + 2, :w + 12]          # rows -2..h+1
                buf = np.zeros((h + 4, cols), np.uint16)
                buf[:, :w + 12] = rows
                # pairs x chunks x (upper 4, lower 4)
                pairs = buf.reshape((h + 4) // 2, 2, nch, 4).transpose(0, 2, 1, 3)
                f.write(struct.pack("<BHHHI", 2, h, w, nch, n_units))
                f.write(pairs.astype("<u2").tobytes())

                err = rec["err"].astype(np.int64)
                corr = round2signed(err * rec["scale_val"], 12 - bd)
                exp = np.full((h, ng * 4, 2), DC, np.int8)
                exp[:, :w, 0] = err
                exp[:, :w, 1] = corr
                # bands x groups x (row0 c0..3, row1 c0..3) x (err, corr)
                exp = exp.reshape(h // 2, 2, ng, 4, 2).transpose(0, 2, 1, 3, 4)
                f.write(exp.astype(np.int8).tobytes())
                n_units += 1
            if max_units is not None and n_units >= max_units:
                break
        f.write(struct.pack("<B", 0))
    print(f"wrote {n_units} segments to {out}")


if __name__ == "__main__":
    args = sys.argv[1:]
    if "--full" in args:
        args.remove("--full")
        MAC_FULL = IDX_FULL = True
    if "--mac-full" in args:
        args.remove("--mac-full")
        MAC_FULL = True
    if "--idx-full" in args:
        args.remove("--idx-full")
        IDX_FULL = True
    if "--fip" in args:
        args.remove("--fip")
        FIP = True
    mx = None
    if "--max" in args:
        i = args.index("--max")
        mx = int(args[i + 1])
        del args[i:i + 2]
    main(args[0], [Path(p) for p in args[1:]], mx)
