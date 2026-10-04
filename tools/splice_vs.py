#!/usr/bin/env python3
"""Splice rtl/wip/frontend_vs.v into rtl/gdf_core.v (one-off edit helper).

Replaces the region from the dashes line above "// segment control: pass k"
up to (not including) "// stage 5: class and raw gradient features" and adds
the VS parameter to the module header.
"""
import shutil
import sys

ROOT = "/mnt/g/AV2"
core = f"{ROOT}/rtl/gdf_core.v"
front = f"{ROOT}/rtl/wip/frontend_vs.v"

lines = open(core).read().split("\n")
fe = open(front).read().rstrip("\n").split("\n")

i0 = next(i for i, l in enumerate(lines) if "// segment control: pass k" in l)
assert lines[i0 - 1].strip().startswith("// ----"), lines[i0 - 1]
i0 -= 1
i1 = next(i for i, l in enumerate(lines) if "// stage 5: class and raw gradient features" in l)
assert i1 > i0
print(f"replacing lines {i0 + 1}..{i1} ({i1 - i0} lines) with {len(fe)} lines")

hdr = next(i for i, l in enumerate(lines) if l.startswith("  parameter FIP   = 0"))
end_hdr = next(i for i in range(hdr, hdr + 10) if lines[i].startswith(")("))
new_hdr = lines[hdr:end_hdr]
new_hdr[0] = new_hdr[0].replace("parameter FIP   = 0 ", "parameter FIP   = 0,")
new_hdr += [
    "  parameter VS    = 0            // 1: column-major stripe scan (requires LA = 1):",
    "                                 //    input words chunk-major (for c: for p), a",
    "                                 //    column buffer of H/2+2 words replaces the",
    "                                 //    six width-dependent line buffers",
]
out = lines[:hdr] + new_hdr + lines[end_hdr:i0] + fe + [""] + lines[i1:]
if "--dry" in sys.argv:
    print("\n".join(new_hdr))
    sys.exit(0)
shutil.copy(core, f"{ROOT}/rtl/gdf_core_v3_rowmajor.v.bak")
open(core, "w").write("\n".join(out))
print("written", core)
