#!/usr/bin/env python3
"""Fakeram45 macros of the memories of the joint LR/GDF stage (FreePDK45).

The array models come from bsg_fakeram (asic/bsg_fakeram, CACTI 7 with the
'ram' cache type, i.e. the models of the fakeram45 macros of the OpenROAD flow,
which this reproduces up to orientation), extended with one read and one write
port (1r1w).  This script writes the LEF, Liberty and Verilog views for three
port types, without bit masks (the stage never writes part of a word):
  1r1w  clk, re_in, raddr_in, rd_out, we_in, waddr_in, wd_in
  1rw   clk, ce_in, we_in, addr_in, wd_in, rd_out
  rom   clk, ce_in, addr_in, rd_out   (a 1rw array with fixed contents)
Read data are registered (one cycle) and hold while the port is not read; a
read of the address being written returns the old word.

LEF as in bsg_fakeram: signal pins on metal3 at the left edge (in groups),
VDD/VSS straps on metal4, obstructions on metal1-4.  A macro whose pins do not
fit on its left edge is turned or, if that is not enough, made taller.
Liberty: CACTI access time as clock-to-output, 50-ps setup and hold, CACTI
cycle time as minimum period, the CACTI read and write energy per access on
the rising clock edge, conditioned on the read and write enables, and the CACTI
standby leakage.  The signal pins carry no internal energy (CACTI's access
energies cover the array; the pin loads are part of the net power).

Usage: gen_gdf_macros.py <cfg.json> <out_dir> <cacti_dir>
       cfg: the bsg_fakeram process keys and a list "srams" of
       {"name", "width", "depth", "ports": "1r1w"|"1rw"|"rom", "init": hexfile,
        "read": "always" (read enable tied high in the stage)}
"""
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'bsg_fakeram', 'scripts'))
from utils.class_process import Process    # noqa: E402
from utils.class_memory import Memory      # noqa: E402


def pin_groups(kind, bits, aw):
    """Signal pins (name, is_input) in groups, bottom to top."""
    def bus(n, w, i=True):
        return [('%s[%d]' % (n, k), i) for k in range(w)]
    if kind == '1r1w':
        return [bus('rd_out', bits, False), bus('wd_in', bits),
                bus('raddr_in', aw), bus('waddr_in', aw),
                [('we_in', True), ('re_in', True), ('clk', True)]]
    if kind == '1rw':
        return [bus('rd_out', bits, False), bus('wd_in', bits), bus('addr_in', aw),
                [('we_in', True), ('ce_in', True), ('clk', True)]]
    return [bus('rd_out', bits, False), bus('addr_in', aw),
            [('ce_in', True), ('clk', True)]]


def fit_pins(mem, npins):
    """Turn or enlarge the macro until its pins fit on the left edge."""
    pr = mem.process
    off = 10 * pr.pinPitch_um

    def tracks(h):
        return math.floor((h - 2 * off) / pr.pinPitch_um)
    w, h = mem.width_um, mem.height_um
    note = ''
    if tracks(h) < npins and tracks(w) > tracks(h):
        w, h = h, w
        note = 'turned'
    if tracks(h) < npins:
        need = (npins + 1) * pr.pinPitch_um + 2 * off
        h = math.ceil(need * 1000.0 / pr.snapHeight_nm) * pr.snapHeight_nm / 1000.0
        note += ' enlarged (pin-limited)'
    # keep both sides on the snap grids of the process
    w = math.ceil(round(w * 1000.0) / pr.snapWidth_nm) * pr.snapWidth_nm / 1000.0
    h = math.ceil(round(h * 1000.0) / pr.snapHeight_nm) * pr.snapHeight_nm / 1000.0
    mem.width_um, mem.height_um = w, h
    mem.area_um2 = w * h
    return note.strip()


def write_lef(mem, groups, path):
    pr = mem.process
    name, w, h = mem.name, mem.width_um, mem.height_um
    mpw, ph, mpp = pr.pinWidth_um, pr.pinHeight_um, pr.pinPitch_um
    mp = pr.metalPrefix
    flip = pr.flipPins.lower() == 'true'
    x_off = y_off = 10 * mpp
    npins = sum(len(g) for g in groups)
    ntr = math.floor((h - 2 * y_off) / mpp)
    assert ntr >= npins, (name, ntr, npins)
    tc = 1
    while npins * (tc + 1) < ntr:
        tc += 1
    pitch = mpp * tc
    gap = max(pitch, math.floor((ntr - npins * tc) / max(1, len(groups) - 1)) * mpp)
    # pin centres
    # pin centres on the track grid: the groups in order, a gap between groups
    ys, y = [], y_off
    for gi, g in enumerate(groups):
        if gi:
            y += gap - pitch
        for _ in g:
            ys.append(y)
            y += pitch
    assert ys[-1] + mpw / 2 <= h - y_off + 1e-6, (name, ys[-1], h)
    pins = [p for g in groups for p in g]
    layer = mp + ('3' if flip else '4')
    hpw = mpw / 2.0
    L = []
    a = L.append
    # header, then one pin per track at the left edge
    a('VERSION 5.7 ;')
    a('BUSBITCHARS "[]" ;')
    a('MACRO %s' % name)
    a('  FOREIGN %s 0 0 ;' % name)
    a('  SYMMETRY X Y R90 ;')
    a('  SIZE %.3f BY %.3f ;' % (w, h))
    a('  CLASS BLOCK ;')
    for (pn, inp), yc in zip(pins, ys):
        a('  PIN %s' % pn)
        a('    DIRECTION %s ;' % ('INPUT' if inp else 'OUTPUT'))
        a('    USE %s ;' % ('CLOCK' if pn == 'clk' else 'SIGNAL'))
        a('    SHAPE ABUTMENT ;')
        a('    PORT')
        a('      LAYER %s ;' % layer)
        a('      RECT %.3f %.3f %.3f %.3f ;' % (0, yc - hpw, ph if flip else mpw, yc + hpw))
        a('    END')
        a('  END %s' % pn)
    # supply straps on metal4 (vertical when flipped)
    sw = mpw * 4
    shw = sw / 2
    spitch = mpp * 8
    for net, use, start in (('VSS', 'GROUND', 0), ('VDD', 'POWER', 1)):
        a('  PIN %s' % net)
        a('    DIRECTION INOUT ;')
        a('    USE %s ;' % use)
        a('    PORT')
        a('      LAYER %s4 ;' % mp)
        if flip:
            x = x_off + start * spitch
            while x <= w - x_off:
                a('      RECT %.3f %.3f %.3f %.3f ;' % (x - shw, y_off, x + shw, h - y_off))
                x += spitch * 2
        else:
            y = y_off + start * spitch
            while y <= h - y_off:
                a('      RECT %.3f %.3f %.3f %.3f ;' % (x_off, y - shw, w - x_off, y + shw))
                y += spitch * 2
        a('    END')
        a('  END %s' % net)
    # obstructions
    a('  OBS')
    a('    LAYER %s1 ;' % mp)
    a('    RECT 0 0 %.3f %.3f ;' % (w, h))
    a('    LAYER %s2 ;' % mp)
    a('    RECT 0 0 %.3f %.3f ;' % (w, h))

    def pin_gaps(width):
        prev = 0.0
        for yc in ys:
            a('    RECT 0 %.3f %.3f %.3f ;' % (prev, width, yc - mpw / 2))
            prev = yc + mpw / 2
        a('    RECT 0 %.3f %.3f %.3f ;' % (prev, width, h))
    a('    LAYER %s3 ;' % mp)
    if flip:
        a('    RECT %.3f 0 %.3f %.3f ;' % (ph, w, h))
        pin_gaps(ph)
    else:
        a('    RECT 0 0 %.3f %.3f ;' % (w, h))
    a('    LAYER %s4 ;' % mp)
    if flip:
        a('    RECT 0 0 %.3f %.3f ;' % (w, y_off))
        a('    RECT 0 %.3f %.3f %.3f ;' % (h - y_off, w, h))
        prev, x = 0.0, x_off
        while x <= w - x_off:
            a('    RECT %.3f %.3f %.3f %.3f ;' % (prev, y_off, x - shw, h - y_off))
            prev = x + shw
            x += spitch
        a('    RECT %.3f %.3f %.3f %.3f ;' % (prev, y_off, w, h - y_off))
    else:
        a('    RECT %.3f 0 %.3f %.3f ;' % (mpw, x_off, h))
        a('    RECT %.3f 0 %.3f %.3f ;' % (w - x_off, w, h))
        prev, y = 0.0, y_off
        while y <= h - y_off:
            a('    RECT %.3f %.3f %.3f %.3f ;' % (x_off, prev, w - x_off, y - shw))
            prev = y + shw
            y += spitch
        a('    RECT %.3f %.3f %.3f %.3f ;' % (x_off, prev, w - x_off, h))
        pin_gaps(mpw)
    a('    LAYER OVERLAP ;')
    a('    RECT 0 0 %.3f %.3f ;' % (w, h))
    a('  END')
    a('END %s' % name)
    a('')
    a('END LIBRARY')
    open(path, 'w', newline='\n').write('\n'.join(L) + '\n')
    return npins, ntr, tc


# Liberty view: CACTI access time as clock-to-output, 50-ps setup and hold,
# CACTI read and write energy on the rising clock edge, CACTI leakage
def write_lib(mem, kind, path):
    name = mem.name
    bits = mem.width_in_bits
    aw = max(1, math.ceil(math.log2(mem.depth)))
    # table axes as in bsg_fakeram: slews of 1 to 25 FO4, loads of 1 to 100 pin loads
    fo4 = mem.fo4_ps / 1e3
    cin = mem.cap_input_pf
    min_slew, max_slew = fo4, 25 * fo4
    min_load, max_load = cin, 100 * cin
    sl = '%.3f, %.3f' % (min_slew, max_slew)
    ld = '%.3f, %.3f' % (min_load, max_load)
    tcq, tsu, th = mem.access_time_ns, mem.t_setup_ns, mem.t_hold_ns
    e_rd = mem.dyn_read_energy_nj * 1e3     # pJ (pF * V^2)
    e_wr = mem.dyn_write_energy_nj * 1e3
    leak = mem.standby_leakage_per_bank_mW * 1e3   # uW
    V = float(mem.process.voltage)
    L = []
    a = L.append
    a('library(%s) {' % name)
    a('    technology (cmos);')
    a('    delay_model : table_lookup;')
    a('    revision : 1.0;')
    a('    comment : "SRAM model (bsg_fakeram + CACTI 7), asic/macros/gen_gdf_macros.py";')
    a('    time_unit : "1ns";')
    a('    voltage_unit : "1V";')
    a('    current_unit : "1uA";')
    a('    leakage_power_unit : "1uW";')
    a('    nom_process : 1;')
    a('    nom_temperature : 25.000;')
    a('    nom_voltage : %s;' % V)
    a('    capacitive_load_unit (1,pf);')
    a('    pulling_resistance_unit : "1kohm";')
    a('    operating_conditions(tt_1.0_25.0) {')
    a('        process : 1;')
    a('        temperature : 25.000;')
    a('        voltage : %s;' % V)
    a('        tree_type : balanced_tree;')
    a('    }')
    a('    default_cell_leakage_power : 0;')
    a('    default_fanout_load : 1;')
    a('    default_inout_pin_cap : 0.0;')
    a('    default_input_pin_cap : 0.0;')
    a('    default_output_pin_cap : 0.0;')
    a('    default_max_transition : %.3f;' % max_slew)
    a('    default_operating_conditions : tt_1.0_25.0;')
    a('    default_leakage_power_density : 0.0;')
    a('    slew_derate_from_library : 1.000;')
    for k in ('slew_lower_threshold_pct_fall : 20.000', 'slew_upper_threshold_pct_fall : 80.000',
              'slew_lower_threshold_pct_rise : 20.000', 'slew_upper_threshold_pct_rise : 80.000',
              'input_threshold_pct_fall : 50.000', 'input_threshold_pct_rise : 50.000',
              'output_threshold_pct_fall : 50.000', 'output_threshold_pct_rise : 50.000'):
        a('    %s;' % k)
    a('    lu_table_template(%s_mem_out_delay_template) {' % name)
    a('        variable_1 : input_net_transition;')
    a('        variable_2 : total_output_net_capacitance;')
    a('            index_1 ("1000, 1001");')
    a('            index_2 ("1000, 1001");')
    a('    }')
    a('    lu_table_template(%s_mem_out_slew_template) {' % name)
    a('        variable_1 : total_output_net_capacitance;')
    a('            index_1 ("1000, 1001");')
    a('    }')
    a('    lu_table_template(%s_constraint_template) {' % name)
    a('        variable_1 : related_pin_transition;')
    a('        variable_2 : constrained_pin_transition;')
    a('            index_1 ("1000, 1001");')
    a('            index_2 ("1000, 1001");')
    a('    }')
    a('    power_lut_template(%s_energy_template_clkslew) {' % name)
    a('        variable_1 : input_transition_time;')
    a('            index_1 ("1000, 1001");')
    a('    }')
    a('    library_features(report_delay_calculation);')
    a('    type (%s_DATA) {' % name)
    a('        base_type : array ;')
    a('        data_type : bit ;')
    a('        bit_width : %d;' % bits)
    a('        bit_from : %d;' % (bits - 1))
    a('        bit_to : 0 ;')
    a('        downto : true ;')
    a('    }')
    a('    type (%s_ADDRESS) {' % name)
    a('        base_type : array ;')
    a('        data_type : bit ;')
    a('        bit_width : %d;' % aw)
    a('        bit_from : %d;' % (aw - 1))
    a('        bit_to : 0 ;')
    a('        downto : true ;')
    a('    }')
    a('cell(%s) {' % name)
    a('    area : %.3f;' % mem.area_um2)
    a('    interface_timing : true;')
    a('    memory() {')
    a('        type : %s;' % ('rom' if kind == 'rom' else 'ram'))
    a('        address_width : %d;' % aw)
    a('        word_width : %d;' % bits)
    a('    }')
    # clock pin: access energies on the rising edge
    # OpenSTA does not propagate activities over tie-cell nets and evaluates a
    # condition on them as false: memories whose read enable the stage ties
    # high ("read": "always") read on every clock edge
    # access energies of the port type, each with the enable that conditions it
    if kind == '1r1w':
        acc = [(None if mem.read_always else 're_in', e_rd), ('we_in', e_wr)]
    elif kind == '1rw':
        # the stage ties ce_in high, and OpenSTA evaluates a condition on a
        # tie-cell net as false: conditions on the write enable only
        acc = [('!we_in', e_rd), ('we_in', e_wr)]
    else:
        acc = [(None, e_rd)]
    a('    pin(clk) {')
    a('        direction : input;')
    a('        capacitance : %.3f;' % (cin * 5))
    a('        clock : true;')
    a('        min_period : %.3f ;' % mem.cycle_time_ns)
    for cond, e in acc:
        a('        internal_power() {')
        if cond:
            a('            when : "%s";' % cond)
        a('            rise_power(%s_energy_template_clkslew) {' % name)
        a('                index_1 ("%s");' % sl)
        a('                values ("%.4f, %.4f")' % (e, e))
        a('            }')
        a('            fall_power(%s_energy_template_clkslew) {' % name)
        a('                index_1 ("%s");' % sl)
        a('                values ("0.0000, 0.0000")')
        a('            }')
        a('        }')
    a('    }')

    def constrained(pname, bus_type=None, extra=()):
        if bus_type:
            a('    bus(%s) {' % pname)
            a('        bus_type : %s;' % bus_type)
        else:
            a('    pin(%s) {' % pname)
        for e in extra:
            a(e)
        a('        direction : input;')
        a('        capacitance : %.3f;' % cin)
        for tt, v in (('setup_rising', tsu), ('hold_rising', th)):
            a('        timing() {')
            a('            related_pin : clk;')
            a('            timing_type : %s ;' % tt)
            for rf in ('rise_constraint', 'fall_constraint'):
                a('            %s(%s_constraint_template) {' % (rf, name))
                a('                index_1 ("%s");' % sl)
                a('                index_2 ("%s");' % sl)
                a('                values ( "%.3f, %.3f", "%.3f, %.3f" )' % (v, v, v, v))
                a('            }')
            a('        }')
        a('    }')
    raddr = 'raddr_in' if kind == '1r1w' else 'addr_in'
    waddr = 'waddr_in' if kind == '1r1w' else 'addr_in'
    # read data
    # read data: clock-to-output delay, constant over slew and load
    a('    bus(rd_out) {')
    a('        bus_type : %s_DATA;' % name)
    a('        direction : output;')
    a('        max_capacitance : %.3f;' % max_load)
    a('        memory_read() {')
    a('            address : %s;' % raddr)
    a('        }')
    a('        timing() {')
    a('            related_pin : "clk" ;')
    a('            timing_type : rising_edge;')
    a('            timing_sense : non_unate;')
    for cr in ('cell_rise', 'cell_fall'):
        a('            %s(%s_mem_out_delay_template) {' % (cr, name))
        a('                index_1 ("%s");' % sl)
        a('                index_2 ("%s");' % ld)
        a('                values ( "%.3f, %.3f", "%.3f, %.3f" )' % (tcq, tcq, tcq, tcq))
        a('            }')
    for tr in ('rise_transition', 'fall_transition'):
        a('            %s(%s_mem_out_slew_template) {' % (tr, name))
        a('                index_1 ("%s");' % ld)
        a('                values ("%.3f, %.3f")' % (min_slew, max_slew))
        a('            }')
    a('        }')
    a('    }')
    if kind == '1r1w':
        constrained('re_in')
        constrained('raddr_in', '%s_ADDRESS' % name)
        constrained('we_in')
        constrained('waddr_in', '%s_ADDRESS' % name)
    elif kind == '1rw':
        constrained('ce_in')
        constrained('we_in')
        constrained('addr_in', '%s_ADDRESS' % name)
    else:
        constrained('ce_in')
        constrained('addr_in', '%s_ADDRESS' % name)
    if kind != 'rom':
        constrained('wd_in', '%s_DATA' % name,
                    ('        memory_write() {', '            address : %s;' % waddr,
                     '            clocked_on : "clk";', '        }'))
    a('    cell_leakage_power : %.3f;' % leak)
    a('}')
    a('')
    a('}')
    open(path, 'w', newline='\n').write('\n'.join(L) + '\n')


V_1R1W = '''\
// {name}: {depth} x {bits} SRAM, one read and one write port (fakeram45 model)
module {name} (clk, re_in, raddr_in, rd_out, we_in, waddr_in, wd_in);
  parameter BITS = {bits};
  parameter WORD_DEPTH = {depth};
  parameter ADDR_WIDTH = {aw};
  input                   clk, re_in, we_in;
  input  [ADDR_WIDTH-1:0] raddr_in, waddr_in;
  input  [BITS-1:0]       wd_in;
  output reg [BITS-1:0]   rd_out;
{body}endmodule
'''
B_1R1W = '''\
  reg [BITS-1:0] mem [0:WORD_DEPTH-1];
  always @(posedge clk) begin
    if (re_in) rd_out <= mem[raddr_in];
    if (we_in) mem[waddr_in] <= wd_in;
  end
'''
V_1RW = '''\
// {name}: {depth} x {bits} SRAM, one read-write port (fakeram45 model)
module {name} (clk, ce_in, we_in, addr_in, wd_in, rd_out);
  parameter BITS = {bits};
  parameter WORD_DEPTH = {depth};
  parameter ADDR_WIDTH = {aw};
  input                   clk, ce_in, we_in;
  input  [ADDR_WIDTH-1:0] addr_in;
  input  [BITS-1:0]       wd_in;
  output reg [BITS-1:0]   rd_out;
{body}endmodule
'''
B_1RW = '''\
  reg [BITS-1:0] mem [0:WORD_DEPTH-1];
  always @(posedge clk)
    if (ce_in) begin
      if (we_in) mem[addr_in] <= wd_in;
      else       rd_out <= mem[addr_in];
    end
'''
V_ROM = '''\
// {name}: {depth} x {bits} ROM (an SRAM array of the same size, fakeram45 model)
module {name} (clk, ce_in, addr_in, rd_out);
  parameter BITS = {bits};
  parameter WORD_DEPTH = {depth};
  parameter ADDR_WIDTH = {aw};
  input                   clk, ce_in;
  input  [ADDR_WIDTH-1:0] addr_in;
  output reg [BITS-1:0]   rd_out;
{body}endmodule
'''
B_ROM = '''\
  reg [BITS-1:0] mem [0:WORD_DEPTH-1];
  initial $readmemh("{init}", mem);
  always @(posedge clk)
    if (ce_in) rd_out <= mem[addr_in];
'''


# simulation model (<name>.v) and black box for synthesis (<name>.bb.v)
def write_verilog(mem, kind, init, out_dir):
    aw = max(1, math.ceil(math.log2(mem.depth)))
    tmpl, body = {'1r1w': (V_1R1W, B_1R1W), '1rw': (V_1RW, B_1RW), 'rom': (V_ROM, B_ROM)}[kind]
    kw = dict(name=mem.name, bits=mem.width_in_bits, depth=mem.depth, aw=aw)
    open(os.path.join(out_dir, mem.name + '.v'), 'w', newline='\n').write(
        tmpl.format(body=body.format(init=init or ''), **kw))
    open(os.path.join(out_dir, mem.name + '.bb.v'), 'w', newline='\n').write(
        '(* blackbox *)\n' + tmpl.format(body='', **kw))


def main():
    # the configuration is JSON with comment lines; one CACTI run per memory
    cfg, out_dir, cacti = sys.argv[1:4]
    with open(cfg) as f:
        data = json.loads('\n'.join(l for l in f if not l.strip().startswith('#')))
    proc = Process(data)
    rows = []
    for s in data['srams']:
        kind = s['ports']
        sd = dict(name=s['name'], width=s['width'], depth=s['depth'], banks=1, type='ram',
                  ports='1r1w' if kind == '1r1w' else '1rw')
        mem = Memory(proc, sd, out_dir, cacti)
        mem.read_always = s.get('read') == 'always'
        w0, h0 = mem.width_um, mem.height_um
        aw = max(1, math.ceil(math.log2(mem.depth)))
        groups = pin_groups(kind, mem.width_in_bits, aw)
        note = fit_pins(mem, sum(len(g) for g in groups))
        d = mem.results_dir
        npins, ntr, tc = write_lef(mem, groups, os.path.join(d, mem.name + '.lef'))
        write_lib(mem, kind, os.path.join(d, mem.name + '.lib'))
        write_verilog(mem, kind, s.get('init'), d)
        rows.append((mem.name, kind, mem.depth, mem.width_in_bits, w0, h0, mem.width_um,
                     mem.height_um, mem.area_um2, mem.access_time_ns, mem.cycle_time_ns,
                     mem.dyn_read_energy_nj * 1e3, mem.dyn_write_energy_nj * 1e3,
                     mem.standby_leakage_per_bank_mW, npins, ntr, note))
    hdr = ('name kind depth width cacti_w cacti_h w_um h_um area_um2 tcq_ns tcyc_ns '
           'e_rd_pJ e_wr_pJ leak_mW pins tracks note')
    with open(os.path.join(out_dir, 'macros.txt'), 'w', newline='\n') as f:
        f.write(hdr + '\n')
        for r in rows:
            f.write('%s %s %d %d %.2f %.2f %.3f %.3f %.1f %.3f %.3f %.3f %.3f %.4f %d %d %s\n'
                    % (r[:16] + (r[16] or '-',)))
    print(open(os.path.join(out_dir, 'macros.txt')).read())


if __name__ == '__main__':
    main()
