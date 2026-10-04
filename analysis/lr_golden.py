#!/usr/bin/env python3
"""Bit-exact model of AV2 luma loop restoration (PC-Wiener and Wiener-NS).

Reads the LR stripe records written by the instrumented AVM decoder
(AVM_LR_DUMP, see avm/av2/common/tcas_instr.h) and recomputes the LR output
of every sample:
  * the 4x4 class comes from the record (the PC-Wiener classifier itself is
    checked by pcw_golden.py) or, with --classify, from pcw_golden.classify;
  * PC-Wiener: filter = bank[set][to_64[set][class]] (12 pairs + centre);
  * Wiener-NS: sub-class = to_n[set][class] (n = num_classes > 1), taps of
    that sub-class (16 pairs), centre = -2 * sum(taps);
  * y = clip(Round2Signed(c0 * x0 + sum_k c_k (x_{+d_k} + x_{-d_k}), 7)).

Usage: lr_golden.py [--classify] <file.lrdump> [...]
"""
import re
import struct
import sys
from collections import Counter
from pathlib import Path

import numpy as np

AVM = Path(__file__).resolve().parents[1] / "avm" / "av2" / "common"
HDR_FIELDS = ("rtype", "width", "height", "procunit_width", "bit_depth",
              "base_qindex", "qindex_offset", "set_index", "num_classes",
              "skip_pcw", "tskip_zero", "order_hint", "v_start", "h_start",
              "bv", "bh", "mi_rows", "mi_cols", "n_pu", "class_restrict",
              "compute_cls", "frame_w", "frame_h", "has_lossless")
RESTORE_NONE, RESTORE_PC_WIENER, RESTORE_WIENER_NONSEP = 0, 1, 2
PREC = 7                                   # PC_WIENER_PREC_FILTER, WIENERNS_PREC_BITS_Y

# (row, col) of the forward sample of each tap pair, in coefficient order
# (LUMA_SHAPE_SYM_LARGEC_16; PC-Wiener uses the first 12 pairs).
PAIRS = [(1, 0), (0, 1), (2, 0), (0, 2), (1, 1), (-1, 1), (2, 1), (2, -1),
         (1, 2), (1, -2), (3, 0), (0, 3), (4, 0), (0, 4), (3, 3), (3, -3)]


def _c_array(text, name):
    m = re.search(name + r"\s*\[[^\]]*\](?:\s*\[[^\]]*\])?\s*=\s*\{(.*?)\};", text, re.S)
    body = re.sub(r"//[^\n]*", "", m.group(1))
    return [int(x) for x in re.findall(r"-?\d+", body)]


_H = (AVM / "pc_wiener_filters.h").read_text()
BANK = np.array([_c_array(_H, f"pcwiener_filters_luma_{s}") for s in range(4)],
                np.int64).reshape(4, 64, 13)
SUBCLS = {n: np.array([_c_array(_H, f"pc_wiener_sub_classify_to_{n}_{s}")
                       for s in range(4)], np.int64)
          for n in (64, 16, 12, 8, 6, 4, 3, 2)}
for n, t in SUBCLS.items():
    assert t.shape == (4, 256) and t.max() < n, n


def r2s(x, n):
    """ROUND_POWER_OF_TWO_SIGNED on numpy arrays."""
    h = 1 << (n - 1)
    return np.where(x < 0, -((-x + h) >> n), (x + h) >> n)


def read_records(path):
    data = Path(path).read_bytes()
    pos = 0
    while pos < len(data):
        assert data[pos:pos + 4] == b"LRSU", f"bad magic at {pos}"
        hdr = dict(zip(HDR_FIELDS, struct.unpack_from("<24i", data, pos + 4)))
        pos += 4 + 96
        h, w, bv, bh = hdr["height"], hdr["width"], hdr["bv"], hdr["bh"]
        mr, mc, npu = hdr["mi_rows"], hdr["mi_cols"], hdr["n_pu"]
        pu = np.frombuffer(data, np.int32, npu, pos)
        pos += 4 * npu
        n = (h + 2 * bv) * (w + 2 * bh)
        dgd = np.frombuffer(data, np.uint16, n, pos).reshape(h + 2 * bv, w + 2 * bh)
        pos += 2 * n
        tsk = np.frombuffer(data, np.uint8, mr * mc, pos).reshape(mr, mc)
        pos += mr * mc
        cls = np.frombuffer(data, np.uint8, mr * mc, pos).reshape(mr, mc)
        pos += mr * mc
        lut = np.frombuffer(data, np.int32, 1024, pos).reshape(256, 4)
        pos += 4096
        taps = np.frombuffer(data, np.int16, 16 * 32, pos).reshape(16, 32)
        pos += 1024
        dst = np.frombuffer(data, np.uint16, h * w, pos).reshape(h, w)
        pos += 2 * h * w
        yield dict(hdr, pu_type=pu.astype(np.int64), dgd=dgd.astype(np.int64),
                   tskip=tsk.astype(np.int64), cls=cls.astype(np.int64),
                   qval_lut=lut.astype(np.int64), taps=taps.astype(np.int64),
                   dst=dst.astype(np.int64))


def block_filters(rec, cls):
    """Coefficients (mi_rows, mi_cols, 17): 16 pair taps + centre (singleton)."""
    mr, mc = cls.shape
    s = rec["set_index"]
    coef = np.zeros((mr, mc, 17), np.int64)
    if rec["rtype"] == RESTORE_PC_WIENER:
        f = BANK[s][SUBCLS[64][s][cls]]                  # (mr, mc, 13)
        coef[..., :12] = f[..., :12]
        coef[..., 16] = (1 << PREC) + f[..., 12]
    else:
        n = rec["num_classes"]
        sub = SUBCLS[n][s][cls] if n > 1 else np.zeros_like(cls)
        t = rec["taps"][sub][..., :16]                   # (mr, mc, 16)
        coef[..., :16] = t
        coef[..., 16] = (1 << PREC) - 2 * t.sum(axis=-1)
    return coef


def lr_filter(rec, cls):
    h, w, bv, bh = rec["height"], rec["width"], rec["bv"], rec["bh"]
    x = rec["dgd"]
    x0 = x[bv:bv + h, bh:bh + w]
    coef = block_filters(rec, cls)
    cs = np.repeat(np.repeat(coef, 4, 0), 4, 1)[:h, :w]  # per-sample coefficients
    acc = cs[..., 16] * x0
    for k, (dr, dc) in enumerate(PAIRS):
        p = (x[bv + dr:bv + dr + h, bh + dc:bh + dc + w] +
             x[bv - dr:bv - dr + h, bh - dc:bh - dc + w])
        acc = acc + cs[..., k] * p
    y = np.clip(r2s(acc, PREC), 0, (1 << rec["bit_depth"]) - 1)
    pw = rec["procunit_width"]
    for p, t in enumerate(rec["pu_type"]):
        if t == RESTORE_NONE:                            # copied processing unit
            y[:, p * pw:(p + 1) * pw] = x0[:, p * pw:(p + 1) * pw]
    return y


def vertical_replication_ok(rec):
    """Rows beyond the two saved rows repeat the outermost saved row."""
    x, bv, h = rec["dgd"], rec["bv"], rec["height"]
    top = all((x[bv - k] == x[bv - 2]).all() for k in (3, 4))
    bot = all((x[bv + h + k] == x[bv + h + 1]).all() for k in (2, 3))
    return top and bot


def main(argv):
    use_cls = "--classify" in argv
    paths = [a for a in argv if not a.startswith("--")]
    if use_cls:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        import pcw_golden
    stats = Counter()
    for path in paths:
        for rec in read_records(path):
            if rec["has_lossless"] or rec["skip_pcw"] or rec["class_restrict"] >= 0:
                stats["skipped"] += 1
                continue
            cls = rec["cls"]
            needs_cls = rec["rtype"] == RESTORE_PC_WIENER or rec["num_classes"] > 1
            if use_cls and needs_cls:
                # AVM classifies each processing unit (64 columns) separately
                cls = np.zeros_like(rec["cls"])
                pw = rec["procunit_width"]
                for p in range(rec["n_pu"]):
                    x0 = p * pw
                    wp = min(pw, rec["width"] - x0)
                    m0, mc = x0 // 4, (wp + 3) // 4
                    pc = dict(rec, bv=3, width=wp, mi_cols=mc, classify_only=0,
                              dgd=rec["dgd"][1:-1, x0:x0 + wp + 2 * rec["bh"]],
                              tskip=rec["tskip"][:, m0:m0 + mc])
                    cls[:, m0:m0 + mc] = pcw_golden.classify(pc)
                stats["cls_blocks"] += cls.size
                stats["cls_mismatch"] += int((cls != rec["cls"]).sum())
            y = lr_filter(rec, cls)
            bad = int((y != rec["dst"]).sum())
            key = {RESTORE_PC_WIENER: "pcw", RESTORE_WIENER_NONSEP: "wns"}[rec["rtype"]]
            stats[key + "_stripes"] += 1
            stats[key + "_samples"] += y.size
            stats[key + "_mismatch"] += bad
            stats["pu_none"] += int((rec["pu_type"] == RESTORE_NONE).sum())
            stats["pu_total"] += len(rec["pu_type"])
            stats[f"ncls{rec['num_classes'] if key == 'wns' else 0}"] += 1
            stats[f"set{rec['set_index']}"] += 1
            stats["vrep_bad"] += 0 if vertical_replication_ok(rec) else 1
    for k in sorted(stats):
        print(f"{k:14s} {stats[k]}")
    ok = stats["pcw_mismatch"] == 0 and stats["wns_mismatch"] == 0 and stats["cls_mismatch"] == 0
    print("RESULT", "PASS" if ok else "FAIL")
    return ok


if __name__ == "__main__":
    sys.exit(0 if main(sys.argv[1:]) else 1)
