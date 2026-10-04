"""Reader for the per-unit GDF dumps written by the instrumented AVM decoder
(see avm/av2/common/tcas_instr.h for the record layout)."""
import numpy as np

HDR_FIELDS = ("frame_idx", "order_hint", "frame_w", "frame_h", "bit_depth",
              "i_min", "i_max", "j_min", "j_max", "qp_idx", "ref_dst_idx",
              "pxl_shift", "scale_val", "err_shift", "has_lossless", "apron")


# one dict per GDFU record: header fields, input window with its apron,
# expected error, LR output and final output of the unit
def read_records(path):
    data = np.fromfile(path, dtype=np.uint8)
    off = 0
    while off < len(data):
        if bytes(data[off:off + 4]) != b"GDFU":
            raise ValueError(f"{path}: bad magic at offset {off}")
        off += 4
        hdr = data[off:off + 64].view("<i4")
        off += 64
        rec = dict(zip(HDR_FIELDS, (int(v) for v in hdr)))
        h = rec["h"] = rec["i_max"] - rec["i_min"]
        w = rec["w"] = rec["j_max"] - rec["j_min"]
        a = rec["apron"]
        n_win = (h + 2 * a) * (w + 2 * a)
        rec["win"] = data[off:off + 2 * n_win].view("<u2").reshape(h + 2 * a, w + 2 * a)
        off += 2 * n_win
        rec["err"] = data[off:off + 2 * h * w].view("<i2").reshape(h, w)
        off += 2 * h * w
        rec["lr"] = data[off:off + 2 * h * w].view("<u2").reshape(h, w)
        off += 2 * h * w
        rec["out"] = data[off:off + 2 * h * w].view("<u2").reshape(h, w)
        off += 2 * h * w
        yield rec
