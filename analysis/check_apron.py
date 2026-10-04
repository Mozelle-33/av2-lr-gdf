"""Check the vertical-apron structure of GDF unit windows (dumps).

AV2 7.20.2: outside the current stripe only two lines are fetched and the
third+ line is a copy of the second.  If that holds for every dumped unit,
the core only needs rows -2..h+1 (2 saved lines above/below) and can clamp
the row index internally.  Also reports horizontal edge replication.
"""
import sys
from pathlib import Path

import numpy as np

from gdf_dump import read_records


def main(paths):
    # units; units whose rows above / below repeat the second line outside the
    # unit; units at the left / right picture edge and those with replicated
    # columns
    n = top_ok = bot_ok = left_rep = right_rep = left_units = right_units = 0
    for p in paths:
        for r in read_records(p):
            # the window is the unit of h x w samples with an apron of a
            # samples on every side: unit row y is window row a + y
            a, h, w = r["apron"], r["h"], r["w"]
            win = r["win"]
            n += 1
            # rows -a..-3 equal row -2, rows h+2..h+a-1 equal row h+1
            top_ok += all(np.array_equal(win[k], win[a - 2]) for k in range(0, a - 2))
            bot_ok += all(np.array_equal(win[a + h + 1], win[k]) for k in range(a + h + 2, 2 * a + h))
            if r["j_min"] == 0:                  # the columns left of the picture repeat column 0
                left_units += 1
                left_rep += all(np.array_equal(win[:, k], win[:, a]) for k in range(a))
            if r["j_max"] == r["frame_w"]:       # and those right of it the last column
                right_units += 1
                right_rep += all(np.array_equal(win[:, a + w - 1], win[:, k])
                                 for k in range(a + w, 2 * a + w))
    print(f"units {n}: top rows -6..-3 == row -2 in {top_ok}; "
          f"bottom rows h+2..h+5 == row h+1 in {bot_ok}")
    print(f"left picture edge units {left_units}: replicated {left_rep}; "
          f"right edge units {right_units}: replicated {right_rep}")


if __name__ == "__main__":
    main([Path(p) for p in sys.argv[1:]])
