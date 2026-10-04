"""R3: sharing of neighbour differences inside a group of P samples.

Pair feature k of centre c needs s[c+o_k] - s[c] and s[c-o_k] - s[c].  When
both samples of a difference are centres of the same group, the two centres
need the same subtraction with opposite signs, so one subtractor serves both.
Counts unique subtractors per sample for several group shapes.
"""
from gdf_table_stats import COORDS

OFFS = [(dy, dx) for dy, dx in COORDS] + [(-dy, -dx) for dy, dx in COORDS]


def unique_diffs(shape):
    rows, cols = shape
    centres = [(r, c) for r in range(rows) for c in range(cols)]
    pairs = set()
    for (r, c) in centres:
        for dy, dx in OFFS:
            n = (r + dy, c + dx)
            pairs.add(frozenset(((r, c), n)))
    return len(pairs), 36 * len(centres)


print("| group (rows x cols) | subtractors | naive | per sample | saving |")
print("|---|---|---|---|---|")
for shape in [(1, 1), (1, 2), (2, 1), (1, 4), (4, 1), (2, 2), (1, 8), (8, 1), (2, 4), (4, 2),
              (1, 16), (16, 1), (4, 4), (2, 8), (8, 2)]:
    u, naive = unique_diffs(shape)
    p = shape[0] * shape[1]
    print(f"| {shape[0]} x {shape[1]} | {u} | {naive} | {u / p:.2f} | {100 * (1 - u / naive):.1f}% |")
