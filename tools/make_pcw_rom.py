#!/usr/bin/env python3
"""Write the ROM images of gdf_core from the AVM tables:
  rtl/pcw_class.hex  PC-Wiener LUT-to-class table (pc_wiener_lut_to_class_index,
                     4096 x 8 bit) for the class ROM;
  rtl/pcw_sel.hex    LR filter selector (pc_wiener_sub_classify_to_64 of the four
                     quantizer sets, 1024 x 6 bit, address {set, class})."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "analysis"))
from pcw_golden import LUT_TO_CLASS  # noqa: E402
from lr_golden import SUBCLS  # noqa: E402

rtl = Path(__file__).resolve().parents[1] / "rtl"
out = rtl / "pcw_class.hex"
out.write_text("".join(f"{int(v):02x}\n" for v in LUT_TO_CLASS))
print(f"wrote {out} ({LUT_TO_CLASS.size} entries)")
sel = SUBCLS[64].reshape(-1)
out = rtl / "pcw_sel.hex"
out.write_text("".join(f"{int(v):02x}\n" for v in sel))
print(f"wrote {out} ({sel.size} entries)")
