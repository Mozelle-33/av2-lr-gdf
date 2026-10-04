#!/usr/bin/env python3
"""Rewrite a gate-level VCD (nets of the routed netlist, gl_sim.sh) for
OpenSTA read_vcd, which annotates *pins*:

  * every net of the netlist scope becomes the output pin of its driver cell
    (scope <instance>, variable <pin>); bus nets are split into bits;
  * nets driven by top-level ports keep their names (port pins);
  * time is rebased to 0 (OpenSTA divides by the absolute end time);
  * the bits of a bus output of a macro cell (the read data of the SRAM
    macros) become its bit pins <pin>[i].

Usage: vcd_to_pins.py <final.v> <cells.lib[,macro.lib,...]> <in.vcd> <out.vcd> [scope=TOP.gdf_core.u_pnr]
"""
import re
import sys

net_file, lib_file, vin, vout = sys.argv[1:5]
top_scope = sys.argv[5] if len(sys.argv) > 5 else "TOP.gdf_core.u_pnr"

# ---- output pins (and output buses) of every library cell
outs = {}
buses = {}
for lf in lib_file.split(","):
    cell = pin = None
    is_bus = False
    for line in open(lf):
        m = re.match(r"\s*cell\s*\(\s*\"?(\w+)\"?\s*\)", line)
        if m:
            cell, pin = m.group(1), None
            outs.setdefault(cell, set())
            buses.setdefault(cell, set())
            continue
        m = re.match(r"\s*(pin|bus)\s*\(\s*\"?(\w+)\"?\s*\)", line)
        if m:
            pin, is_bus = m.group(2), m.group(1) == "bus"
            continue
        if cell and pin and re.match(r"\s*direction\s*:\s*output", line):
            outs[cell].add(pin)
            if is_bus:
                buses[cell].add(pin)

# ---- driver pin of every net
def norm(n):
    return n.strip().lstrip("\\").strip()

text = open(net_file).read()
# bus wires of the netlist, for a bus pin connected to a whole bus wire
wire_rng = {}
for m in re.finditer(r"^\s*wire\s*\[(\d+):(\d+)\]\s*(\\\S+|\w+)\s*;", text, re.M):
    wire_rng[norm(m.group(3))] = (int(m.group(1)), int(m.group(2)))
driver = {}
n_bus_bits = 0
for m in re.finditer(r"^\s*(\w+)\s+(\\\S+|\w+)\s*\((.*?)\);", text, re.S | re.M):
    cname, inst, body = m.group(1), m.group(2).lstrip("\\"), m.group(3)
    if cname not in outs:
        continue
    for pm in re.finditer(r"\.(\w+)\s*\(((?:[^(){}]|\{[^{}]*\})*)\)", body):
        p, net = pm.group(1), norm(pm.group(2))
        if p not in outs[cname] or not net:
            continue
        if p not in buses[cname]:
            driver[net] = (inst, p)
            continue
        if net.startswith("{"):                 # concatenation, MSB first
            elems = [norm(x) for x in net.strip("{}").split(",")]
            bits = [(len(elems) - 1 - k, e) for k, e in enumerate(elems)]
        else:                                   # a whole bus wire
            msb, lsb = wire_rng[net]
            lo = min(msb, lsb)
            bits = [(i - lo, f"{net}[{i}]") for i in range(lo, max(msb, lsb) + 1)]
        for i, e in bits:
            if e and "'b" not in e:
                driver[e] = (inst, f"{p}[{i}]")
                n_bus_bits += 1
print(f"cells {len(outs)}, driven nets {len(driver)} ({n_bus_bits} by macro bus bits)",
      file=sys.stderr)

# ---- rewrite
fo = open(vout, "w")
scope = []
bus = {}          # vcd id -> list of (bit index lsb-relative, new id) and width
last = {}
next_id = [0]

# short printable identifiers for the new pin variables
def new_id():
    n = next_id[0]
    next_id[0] += 1
    s = "~"
    while True:
        s += chr(33 + n % 94)
        n //= 94
        if n == 0:
            return s

# one pass over the VCD: in the header every net variable is declared again
# for the pins it drives; the value changes are then copied to those pins
n_pin = n_keep = n_bus_bits = 0
with open(vin) as f:
    for line in f:
        t = line.split()
        if t and t[0] == "$scope":
            scope.append(t[2])
        elif t and t[0] == "$upscope":
            scope.pop()
        elif t and t[0] == "$var" and ".".join(scope) == top_scope:
            width, vid, name = int(t[2]), t[3], t[4]
            rng = t[5] if len(t) > 6 and t[5].startswith("[") else None
            if width == 1 and name in driver:
                inst, p = driver[name]
                fo.write(f"$scope module {inst} $end\n$var wire 1 {vid} {p} $end\n$upscope $end\n")
                n_pin += 1
                continue
            if width > 1 and rng:
                msb, lsb = (int(x) for x in rng.strip("[]").split(":"))
                bits = []
                for k in range(width):
                    idx = lsb + k if lsb <= msb else lsb - k
                    net = f"{name}[{idx}]"
                    if net in driver:
                        inst, p = driver[net]
                        nid = new_id()
                        fo.write(f"$scope module {inst} $end\n$var wire 1 {nid} {p} $end\n$upscope $end\n")
                        bits.append((k, nid))
                if bits:
                    bus[vid] = (width, bits)
                    n_bus_bits += len(bits)
                    continue
            n_keep += 1
        elif t and t[0] == "$enddefinitions":
            fo.write(line)
            break
        fo.write(line)
    print(f"pin vars {n_pin}, bus bits {n_bus_bits}, kept {n_keep}", file=sys.stderr)
    t0 = None
    for line in f:
        c = line[0]
        if c == "#":
            tm = int(line[1:])
            if t0 is None:
                t0 = tm
            fo.write(f"#{tm - t0}\n")
        elif c in "bB":
            val, vid = line[1:].split()
            if vid in bus:
                width, bits = bus[vid]
                val = val.rjust(width, "0")      # MSB first
                for k, nid in bits:
                    v = val[width - 1 - k]
                    if last.get(nid) != v:
                        last[nid] = v
                        fo.write(f"{v}{nid}\n")
            else:
                fo.write(line)
        else:
            fo.write(line)
fo.close()
print("done", file=sys.stderr)
