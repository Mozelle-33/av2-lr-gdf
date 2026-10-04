#!/usr/bin/env python3
"""Copy a Liberty file and mark cells dont_use (as ORFS does for Nangate45).

Usage: mark_dont_use.py <in.lib> <out.lib> CELL [CELL ...]
"""
import re
import sys

src, dst, cells = sys.argv[1], sys.argv[2], set(sys.argv[3:])
out, n = [], 0
for line in open(src):
    out.append(line)
    m = re.match(r'\s*cell\s*\(\s*"?([A-Za-z0-9_]+)"?\s*\)\s*\{', line)
    if m and m.group(1) in cells:
        out.append("    dont_use : true ;\n")
        n += 1
open(dst, "w").writelines(out)
print(f"marked {n} cells dont_use")
