"""Aggregate AVM decoder profiling results (scripts/decode_profile.sh output).

Usage: python3 profile_report.py <profile_dir>
Writes <profile_dir>/profile_report.md with the per-stage share of decoding
time and, in particular, the share of the Guided Detail Filter.
"""
import re
import sys
from collections import defaultdict
from pathlib import Path

# timers of the instrumented decoder
STAGES = ["tiles(entropy+recon)", "deblocking", "cdef", "ccso", "gdf_copy_guided",
          "loop_restoration", "gdf_total", "gdf_lap_cls", "gdf_inference",
          "gdf_compensation", "wrapup_total"]


# {stage: milliseconds} from the lines "[tcas] <stage> <time> ms" of a decoder log
def parse_stages(path):
    ms = {}
    for line in path.read_text().splitlines():
        m = re.match(r"\[tcas\]\s+(\S+)\s+([\d.]+) ms", line.strip())
        if m:
            ms[m.group(1)] = float(m.group(2))
    return ms


def main(d):
    d = Path(d)
    rows = []
    # one row per stream: the stage times of the instrumented decoder, and
    # from the summary file the decoding time of the release decoder (CPU
    # time in microseconds) and whether both decoders give the same MD5;
    # stream names are <sequence>_<ai|ra>_q<QP>_s<speed>_f<frames>
    for s in sorted(d.glob("*.stages.txt")):
        name = s.name[:-len(".stages.txt")]
        ms = parse_stages(s)
        summ = d / f"{name}.summary.tsv"
        rel_us, md5 = None, "?"
        if summ.exists():
            f = summ.read_text().split("\t")
            rel_us, md5 = int(f[1]), f[2]
        m = re.match(r"(.+)_(ai|ra)_q(\d+)_s(\d+)_f(\d+)$", name)
        seq, cfg, qp = (m.group(1), m.group(2), int(m.group(3))) if m else (name, "?", 0)
        rows.append(dict(name=name, seq=seq, cfg=cfg, qp=qp, ms=ms, rel_us=rel_us, md5=md5))

    out = ["# AVM decoder stage profile (single thread, AVX2 build)\n"]
    out.append("| stream | cfg | QP | decode (release) ms | GDF % | LR % | CDEF % | CCSO % | deblock % | tiles % | md5 |")
    out.append("|---|---|---|---|---|---|---|---|---|---|---|")
    agg = defaultdict(lambda: defaultdict(float))    # configuration -> stage -> ms
    for r in rows:
        # shares of the total of the instrumented decoder; the GDF share
        # includes the copy of its guide frame
        ms, tot = r["ms"], r["ms"].get("wrapup_total", 0.0)
        if tot <= 0:
            continue
        pct = {k: 100.0 * ms.get(k, 0.0) / tot for k in STAGES}
        gdf = pct["gdf_total"] + pct["gdf_copy_guided"]
        out.append(f"| {r['seq']} | {r['cfg']} | {r['qp']} | "
                   f"{(r['rel_us'] or 0) / 1e3:.1f} | {gdf:.1f} | {pct['loop_restoration']:.1f} | "
                   f"{pct['cdef']:.1f} | {pct['ccso']:.1f} | {pct['deblocking']:.1f} | "
                   f"{pct['tiles(entropy+recon)']:.1f} | {r['md5']} |")
        for k in STAGES:
            agg[r["cfg"]][k] += ms.get(k, 0.0)
    out.append("\n## Aggregate share of decoding time (sum over streams)\n")
    out.append("| stage | " + " | ".join(sorted(agg)) + " |")
    out.append("|---|" + "---|" * len(agg))
    for k in STAGES:
        cells = []
        for cfg in sorted(agg):
            tot = agg[cfg]["wrapup_total"]
            cells.append(f"{100.0 * agg[cfg][k] / tot:.1f} %" if tot else "-")
        out.append(f"| {k} | " + " | ".join(cells) + " |")
    text = "\n".join(out) + "\n"
    (d / "profile_report.md").write_text(text)
    print(text)


if __name__ == "__main__":
    main(sys.argv[1])
