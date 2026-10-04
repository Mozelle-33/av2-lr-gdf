// Verilator testbench for gdf_core: replays a .vec file (tools/make_vectors.py)
// and checks every output sample (err and corr) bit-exactly.
// The core's parallelism is fixed at compile time and must match the RTL
// parameters: GDF_NB row pairs and GDF_GC columns per cycle (default 1, 4).
// Environment GDF_VS=1 selects the column-major word order.
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "Vgdf_core.h"
#include "verilated.h"
#if VM_TRACE
#include "verilated_vcd_c.h"
#endif

#ifndef GDF_NB
#define GDF_NB 1
#endif
#ifndef GDF_GC
#define GDF_GC 4
#endif
static const int NB = GDF_NB, GC = GDF_GC, NS = 2 * NB * GC, IW = 20 * NB * GC;
static const int NWW = (IW + 31) / 32;       // 32-bit words per input word

static Vgdf_core* dut;
static uint64_t cycles = 0;

// optional VCD window (built with --trace): GDF_VCD=<file>; the window starts
// GDF_VCD_SKIP cycles into the GDF_VCD_SEG-th segment of the file and lasts
// GDF_VCD_LEN cycles, across segment boundaries; time unit ps at a 2.5-ns
// clock (400 MHz)
#if VM_TRACE
static VerilatedVcdC* tfp = nullptr;
#endif
static bool trace_started = false;
static long traced = 0, trace_len = 0;
// one VCD sample per clock phase while the window is open
static void dump(int phase) {
#if VM_TRACE
  if (trace_started && traced < trace_len) {
    tfp->dump((vluint64_t)cycles * 2500 + (phase ? 1250 : 0));
    if (phase) traced++;
  }
#else
  (void)phase;
#endif
}

static void pdump();

// one clock cycle with the inputs as they are set
static void tick() {
  dut->clk = 0;
  dut->eval();
  dump(0);
  pdump();
  dut->clk = 1;
  dut->eval();
  dump(1);
  cycles++;
}

template <typename T>
static bool rd(FILE* f, T* v) { return fread(v, sizeof(T), 1, f) == 1; }

// Verilator ports are 32-bit, 64-bit or arrays of 32-bit words by width
static void put(uint32_t& sig, const uint32_t* w) { sig = w[0]; }
static void put(uint64_t& sig, const uint32_t* w) { sig = (uint64_t)w[0] | ((uint64_t)w[1] << 32); }
template <size_t N> static void put(uint32_t (&sig)[N], const uint32_t* w) {
  for (size_t i = 0; i < N; i++) sig[i] = w[i];
}
static void get(const uint32_t& sig, uint32_t* w) { w[0] = sig; }
static void get(const uint64_t& sig, uint32_t* w) { w[0] = (uint32_t)sig; w[1] = (uint32_t)(sig >> 32); }
template <size_t N> static void get(const uint32_t (&sig)[N], uint32_t* w) {
  for (size_t i = 0; i < N; i++) w[i] = sig[i];
}

// optional port trace for replaying a run on a gate-level netlist
// (fpga/power/tb_power_joint.v): GDF_PORTDUMP=<file> writes, for every rising
// edge, the input ports as 36 hex digits (bit 0 up: in_data[79:0], in_gdf,
// in_lr[2:0], in_tskip, in_valid, seg_nch (16), seg_h (7), seg_start,
// cfg_wdata (16), cfg_addr (13), cfg_we, rst); GDF_PORTDUMP_OUT=<file> the
// outputs before the edge as 56 hex digits (out_y[79:0], out_pcw, out_corr,
// out_err, out_group (16), out_band (6), out_valid).  The dump stops
// GDF_VCD_LEN + 64 edges after the window of GDF_VCD_SEG / GDF_VCD_SKIP,
// whose first edge is written to <file>.win.  NB = 1, GC = 4 only.
// GDF_PORTDUMP_C=<file> adds the chroma inputs (22 hex digits: in_c_data
// [79:0], in_c_lr[5:0]) and GDF_PORTDUMP_COUT=<file> the chroma outputs
// before the edge (16 hex digits: out_c_y[39:0], out_c_strip (16),
// out_c_row (6), out_c_valid), one line per edge as well.
static FILE* pdf = nullptr;
static FILE* pof = nullptr;
static FILE* pcf = nullptr;
static FILE* pcof = nullptr;
static long pd_win = -1, pd_stop = -1;
static uint64_t pd_lines = 0;
// helpers of the port traces: OR the bits of v (or of a 64-bit value) into
// bits [lo, lo+w) of a little-endian word array; print the lowest nhex hex
// digits of the array, most significant first
static void setbits(uint32_t* a, int lo, int w, const uint32_t* v) {
  for (int i = 0; i < w; i++)
    if ((v[i / 32] >> (i % 32)) & 1) a[(lo + i) / 32] |= 1u << ((lo + i) % 32);
}
static void setv(uint32_t* a, int lo, int w, uint64_t v) {
  const uint32_t t[2] = {(uint32_t)v, (uint32_t)(v >> 32)};
  setbits(a, lo, w, t);
}
static void hexline(FILE* f, const uint32_t* a, int nhex) {
  for (int d = nhex - 1; d >= 0; d--) fputc("0123456789abcdef"[(a[d / 8] >> (4 * (d % 8))) & 15], f);
  fputc('\n', f);
}
// one line per rising edge into every open trace file (layout above)
static void pdump() {
  if (!pdf || (pd_stop >= 0 && (long)cycles >= pd_stop)) return;
  uint32_t a[5] = {0, 0, 0, 0, 0}, w[8] = {0, 0, 0, 0, 0, 0, 0, 0};
  get(dut->in_data, w);
  setbits(a, 0, 80, w);
  setv(a, 80, 1, dut->in_gdf);
  setv(a, 81, 3, dut->in_lr);
  setv(a, 84, 1, dut->in_tskip);
  setv(a, 85, 1, dut->in_valid);
  setv(a, 86, 16, dut->seg_nch);
  setv(a, 102, 7, dut->seg_h);
  setv(a, 109, 1, dut->seg_start);
  setv(a, 110, 16, dut->cfg_wdata);
  setv(a, 126, 13, dut->cfg_addr);
  setv(a, 139, 1, dut->cfg_we);
  setv(a, 140, 1, dut->rst);
  hexline(pdf, a, 36);
  if (pof) {
    uint32_t o[7] = {0, 0, 0, 0, 0, 0, 0}, y[8] = {0, 0, 0, 0, 0, 0, 0, 0}, e[2] = {0, 0}, c[2] = {0, 0};
    get(dut->out_y, y);
    setbits(o, 0, 80, y);
    setv(o, 80, 8, dut->out_pcw);
    get(dut->out_corr, c);
    setbits(o, 88, 56, c);
    get(dut->out_err, e);
    setbits(o, 144, 56, e);
    setv(o, 200, 16, dut->out_group);
    setv(o, 216, 6, dut->out_band);
    setv(o, 222, 1, dut->out_valid);
    hexline(pof, o, 56);
  }
  if (pcf) {
    uint32_t c[3] = {0, 0, 0}, w[3] = {0, 0, 0};
    get(dut->in_c_data, w);
    setbits(c, 0, 80, w);
    setv(c, 80, 6, dut->in_c_lr);
    hexline(pcf, c, 22);
  }
  if (pcof) {
    uint32_t c[2] = {0, 0};
    setv(c, 0, 40, dut->out_c_y);
    setv(c, 40, 16, dut->out_c_strip);
    setv(c, 56, 6, dut->out_c_row);
    setv(c, 62, 1, dut->out_c_valid);
    hexline(pcof, c, 16);
  }
  pd_lines++;
}

// sample s of an output bus: 7-bit signed (error, correction) or 10-bit
static int sx7(uint64_t v) { v &= 0x7F; return (v & 0x40) ? (int)v - 128 : (int)v; }
static int sample7(const uint32_t* w, int s) {  // w zero-padded to 6 words
  const int bit = 7 * s;
  const uint64_t v = (uint64_t)w[bit / 32] | ((uint64_t)w[bit / 32 + 1] << 32);
  return sx7(v >> (bit % 32));
}
static int sample10(const uint32_t* w, int s) {  // w zero-padded
  const int bit = 10 * s;
  const uint64_t v = (uint64_t)w[bit / 32] | ((uint64_t)w[bit / 32 + 1] << 32);
  return (int)((v >> (bit % 32)) & 0x3FF);
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 2) { fprintf(stderr, "usage: %s <file.vec> [-v]\n", argv[0]); return 2; }
  bool verbose = argc > 2 && !strcmp(argv[2], "-v");
  const char* vse = getenv("GDF_VS");
  bool vs = vse && vse[0] == '1';
  // negative test of the GDF side stream: GDF_IGNORE_OFF=1 keeps in_gdf at 1
  const bool ignore_off = getenv("GDF_IGNORE_OFF") && getenv("GDF_IGNORE_OFF")[0] == '1';
  if (!vs && (NB != 1 || GC != 4)) { fprintf(stderr, "row-major core needs NB=1 GC=4\n"); return 2; }
  // vector file: magic "GDFV", version, then records until type 0
  FILE* f = fopen(argv[1], "rb");
  if (!f) { perror("vec"); return 2; }
  char magic[4]; uint32_t ver;
  if (fread(magic, 1, 4, f) != 4 || memcmp(magic, "GDFV", 4) || !rd(f, &ver)) {
    fprintf(stderr, "bad vector file\n"); return 2;
  }
  // optional VCD window (GDF_VCD*) and port traces (GDF_PORTDUMP*)
  dut = new Vgdf_core;
  const char* vcd = getenv("GDF_VCD");
  const long vcd_seg = getenv("GDF_VCD_SEG") ? atol(getenv("GDF_VCD_SEG")) : 0;
  const long vcd_skip = getenv("GDF_VCD_SKIP") ? atol(getenv("GDF_VCD_SKIP")) : 0;
  trace_len = getenv("GDF_VCD_LEN") ? atol(getenv("GDF_VCD_LEN")) : 1000;
#if VM_TRACE
  if (vcd) {
    Verilated::traceEverOn(true);
    tfp = new VerilatedVcdC;
    dut->trace(tfp, 99);
    tfp->open(vcd);
  }
#else
  if (vcd) { fprintf(stderr, "GDF_VCD needs a --trace build\n"); return 2; }
#endif
  const char* pdn = getenv("GDF_PORTDUMP");
  if (pdn) {
    if (NB != 1 || GC != 4) { fprintf(stderr, "GDF_PORTDUMP needs NB=1 GC=4\n"); return 2; }
    pdf = fopen(pdn, "w");
    if (const char* pon = getenv("GDF_PORTDUMP_OUT")) pof = fopen(pon, "w");
    if (!pdf || (getenv("GDF_PORTDUMP_OUT") && !pof)) { perror("GDF_PORTDUMP"); return 2; }
    if (const char* pcn = getenv("GDF_PORTDUMP_C")) pcf = fopen(pcn, "w");
    if (const char* pcon = getenv("GDF_PORTDUMP_COUT")) pcof = fopen(pcon, "w");
    if ((getenv("GDF_PORTDUMP_C") && !pcf) || (getenv("GDF_PORTDUMP_COUT") && !pcof)) {
      perror("GDF_PORTDUMP_C"); return 2;
    }
  }
  // reset, then one idle cycle
  dut->rst = 1; dut->cfg_we = 0; dut->seg_start = 0; dut->in_valid = 0; dut->in_gdf = 1;
  for (int i = 0; i < 4; i++) tick();
  dut->rst = 0; tick();

  uint64_t segs = 0, samples = 0, bad = 0, seg_cycles_total = 0, cfg_writes = 0;
  uint64_t pcw_blocks = 0, lr_samples = 0, seg_writes = 0, chroma_samples = 0;
  // record type 5: configuration writes during the next segment, each issued
  // once that many input words have been accepted (u32 n, n x (u32 word,
  // u16 addr, u16 data)); used to reload LR coefficient banks ahead of use
  std::vector<uint32_t> sw_at;
  std::vector<uint16_t> sw_addr, sw_data;
  for (;;) {
    uint8_t type;
    if (!rd(f, &type) || type == 0) break;
    if (type == 5) {
      uint32_t n; rd(f, &n);
      for (uint32_t i = 0; i < n; i++) {
        uint32_t at; uint16_t a, d;
        rd(f, &at); rd(f, &a); rd(f, &d);
        sw_at.push_back(at); sw_addr.push_back(a); sw_data.push_back(d);
      }
      continue;
    }
    if (type == 1) {
      uint32_t n; rd(f, &n);
      for (uint32_t i = 0; i < n; i++) {
        uint16_t a, d; rd(f, &a); rd(f, &d);
        dut->cfg_we = 1; dut->cfg_addr = a; dut->cfg_wdata = d;
        tick();
      }
      dut->cfg_we = 0;
      cfg_writes += n;
    } else if (type == 2 || type == 3 || type == 4 || type == 7) {
      // type 2: GDF segment; type 3: PC-Wiener segment (classes checked only);
      // type 4: joint LR/GDF segment, flags 1: err/corr, 2: classes, 4: y;
      // type 7: type 4 followed by the chroma LR of the same region (u16 W_c,
      // u8 check, chroma words and expected output as in type 6)
      const bool pcw = (type == 3 || type == 4 || type == 7);   // transform-skip side stream
      uint16_t H, W, NCH, MR = 0, MC = 0; uint32_t id; uint8_t flags = 1;
      rd(f, &H); rd(f, &W); rd(f, &NCH); rd(f, &id);
      if (pcw) { rd(f, &MR); rd(f, &MC); }
      if (type == 3) flags = 2;
      if (type == 4 || type == 7) rd(f, &flags);
      const bool chk_gdf = flags & 1, chk_cls = flags & 2, chk_y = flags & 4;
      const int npairs = (H + 4) / 2, ng = (W + 3) / 4;
      std::vector<uint16_t> in((size_t)npairs * NCH * 8);
      std::vector<int8_t> exp(chk_gdf ? (size_t)(H / 2) * ng * 8 * 2 : 0);
      std::vector<uint8_t> tsk((size_t)MR * MC), cls(chk_cls ? (size_t)MR * MC : 0),
          pseen(chk_cls ? (size_t)MR * MC : 0, 0);
      std::vector<uint16_t> yexp(chk_y ? (size_t)H * W : 0);
      // flags 8: {GDF off, LR on, coefficient bank} per group (else GDF on,
      // LR on, bank 0)
      std::vector<uint8_t> lri((flags & 8) ? (size_t)ng : 0);
      if (fread(in.data(), 2, in.size(), f) != in.size() ||
          fread(exp.data(), 1, exp.size(), f) != exp.size() ||
          fread(tsk.data(), 1, tsk.size(), f) != tsk.size() ||
          fread(cls.data(), 1, cls.size(), f) != cls.size() ||
          fread(yexp.data(), 2, yexp.size(), f) != yexp.size() ||
          fread(lri.data(), 1, lri.size(), f) != lri.size()) {
        fprintf(stderr, "truncated segment %u\n", id); return 2;
      }
      // type 7: chroma LR of the region
      const bool chroma = (type == 7);
      const int chh = H / 2;
      uint16_t WC = 0; uint8_t cchk = 0;
      if (chroma) { rd(f, &WC); rd(f, &cchk); }
      std::vector<uint16_t> chr(chroma ? (size_t)2 * (chh + 4) * 2 * NCH : 0),
          cexp(chroma ? (size_t)2 * chh * WC : 0);
      std::vector<uint8_t> cside(chroma ? NCH : 0), cseen(cexp.size(), 0);
      if (fread(chr.data(), 2, chr.size(), f) != chr.size() ||
          fread(cside.data(), 1, cside.size(), f) != cside.size() ||
          fread(cexp.data(), 2, cexp.size(), f) != cexp.size()) {
        fprintf(stderr, "truncated chroma part of segment %u\n", id); return 2;
      }
      auto CHS = [&](int pl, int row, int col) -> uint64_t {    // row -2.., column -4..
        return chr[((size_t)pl * (chh + 4) + (row + 2)) * 2 * NCH + (col + 4)] & 0x3FF;
      };
      auto crow = [&](int row, int c) -> uint64_t {             // {V1, V0, U1, U0}
        return CHS(0, row, 2 * c - 4) | (CHS(0, row, 2 * c - 3) << 10) |
               (CHS(1, row, 2 * c - 4) << 20) | (CHS(1, row, 2 * c - 3) << 30);
      };
      if (pcw && !(vs && NB == 1 && GC == 4)) {
        fprintf(stderr, "PC-Wiener/LR records need the column-major core (VS=1 NB=1 GC=4)\n");
        return 2;
      }
      // segment window: row r = picture row r-2 (0..H+3), column x = picture
      // column x-6 (0..4*NCH-1); the vector holds 2x4 chunks in row-pair order
      const int ncol = 4 * NCH;
      auto S = [&](int r, int x) -> uint32_t {
        return in[((size_t)(r / 2) * NCH + x / 4) * 8 + (r % 2) * 4 + x % 4] & 0x3FF;
      };
      // input words of NB pairs x GC columns
      const int nchg = (W + 12 + GC - 1) / GC;  // chunks of GC columns per row
      std::vector<uint32_t> words;
      std::vector<uint8_t> tsw;                // in_tskip per word (PC-Wiener)
      std::vector<uint8_t> lrw;                // {!in_gdf, in_lr} per word
      auto push_word = [&](int c, int p0) {
        // the first pair p = 2m+1 of MI row m carries the flag of MI (m, c-2)
        const int m = (p0 - 1) / 2, mc = c - 2;
        tsw.push_back((pcw && (p0 & 1) && m < MR && mc >= 0 && mc < MC) ? tsk[(size_t)m * MC + mc] : 0);
        // every word of chunk c carries the LR and GDF info of group c - 12/GC
        const int lg = c - 12 / GC;
        lrw.push_back(lg >= 0 && lg < ng ? (lri.empty() ? 4 : lri[lg]) : 0);
        uint32_t w[6] = {0, 0, 0, 0, 0, 0};
        for (int n = 0; n < NB; n++)
          for (int r = 0; r < 2; r++)
            for (int x = 0; x < GC; x++) {
              const int p = p0 + n, col = GC * c + x;
              const uint32_t v = (p < npairs && col < ncol) ? S(2 * p + r, col) : 0;
              const int bit = 10 * ((2 * n + r) * GC + x);
              w[bit / 32] |= v << (bit % 32);
              if (bit % 32 > 22) w[bit / 32 + 1] |= v >> (32 - bit % 32);
            }
        words.insert(words.end(), w, w + NWW);
      };
      if (!vs) {
        for (int p = 0; p < npairs; p++)
          for (int c = 0; c < nchg; c++) push_word(c, p);
      } else {  // column-major: for c: for cycle i (pairs NB*i ..), whole cycles, >= 3
        const int hh = H / 2;
        const int cyc = (NB == 1) ? hh + 2 : std::max(3, (hh + 3) / 2);
        for (int c = 0; c < nchg; c++)
          for (int i = 0; i < cyc; i++) push_word(c, NB * i);
      }
      const size_t nw = words.size() / NWW;
      const int ngc = (W + GC - 1) / GC;       // output groups per band
      std::vector<uint8_t> seen((size_t)(H / 2) * ngc, 0);
      dut->seg_h = H; dut->seg_nch = nchg; dut->seg_start = 1;
      tick();
      dut->seg_start = 0;
      size_t ip = 0, sw = 0;
      uint64_t c0 = cycles, seg_bad = 0;
      int guard = 0;
      for (;;) {
        if (vcd && !trace_started && (long)segs == vcd_seg && (long)(cycles - c0) >= vcd_skip)
          trace_started = true;
        if (pdf && pd_win < 0 && (long)segs == vcd_seg && (long)(cycles - c0) >= vcd_skip) {
          pd_win = (long)cycles;
          pd_stop = pd_win + trace_len + 64;
        }
        if (ip < nw) {
          put(dut->in_data, &words[ip * NWW]);
          dut->in_tskip = tsw[ip]; dut->in_lr = lrw[ip] & 7;
          dut->in_gdf = ignore_off || !(lrw[ip] & 8);
          dut->in_valid = 1;
          if (chroma) {                                 // word (c, p): row p-1 of strip c
            const int c = (int)(ip / (chh + 2)), p = (int)(ip % (chh + 2));
            const uint64_t mr = crow(p - 1, c);
            const uint64_t er = (p == 0) ? crow(-2, c) : (p == chh + 1) ? crow(chh + 1, c) : 0;
            uint32_t cw3[3] = {(uint32_t)mr, (uint32_t)(mr >> 32) | (uint32_t)(er << 8),
                               (uint32_t)(er >> 24)};
            put(dut->in_c_data, cw3);
            dut->in_c_lr = cside[c];
          }
        } else { dut->in_valid = 0; dut->in_tskip = 0; dut->in_lr = 0; dut->in_gdf = 1; }
        if (sw < sw_at.size() && ip >= sw_at[sw]) {   // one write per cycle
          dut->cfg_we = 1; dut->cfg_addr = sw_addr[sw]; dut->cfg_wdata = sw_data[sw];
          sw++;
        } else {
          dut->cfg_we = 0;
        }
        dut->clk = 0; dut->eval(); dump(0);
        bool take = dut->in_valid && dut->in_ready;
        // sample outputs before the edge (registered outputs of previous edge)
        if (chk_cls && dut->out_valid && (dut->out_band & 1)) {
          const int k = dut->out_band >> 1, g = dut->out_group;
          if (k < MR && g < MC) {
            pseen[(size_t)k * MC + g] = 1;
            pcw_blocks++;
            const int want = cls[(size_t)k * MC + g], got = dut->out_pcw;
            if (got != want) {
              if (bad + seg_bad < 10)
                fprintf(stderr, "seg %u block (%d,%d): class %d/%d\n", id, k, g, got, want);
              seg_bad++;
            }
          }
        }
        // a group of NS luma samples of band out_band: restored sample,
        // GDF error and correction against the expected values
        if ((chk_gdf || chk_y) && dut->out_valid) {
          const int b = dut->out_band, g = dut->out_group;
          uint32_t ew[6] = {0, 0, 0, 0, 0, 0}, cw[6] = {0, 0, 0, 0, 0, 0};
          uint32_t yw[8] = {0, 0, 0, 0, 0, 0, 0, 0};
          get(dut->out_err, ew);
          get(dut->out_corr, cw);
          get(dut->out_y, yw);
          for (int s = 0; s < NS; s++) {
            const int row = 2 * b + s / GC, col = GC * g + s % GC;
            if (row >= H || col >= W) continue;
            seen[(size_t)(row / 2) * ngc + col / GC] = 1;
            if (chk_y) {
              const int want = yexp[(size_t)row * W + col], got = sample10(yw, s);
              lr_samples++;
              if (got != want) {
                if (bad + seg_bad < 10)
                  fprintf(stderr, "seg %u row %d col %d: y %d/%d\n", id, row, col, got, want);
                seg_bad++;
              }
            }
            if (!chk_gdf) continue;
            const int8_t* x =
                &exp[(((size_t)(row / 2) * ng + col / 4) * 8 + (row % 2) * 4 + col % 4) * 2];
            if (x[0] == 0x7F) continue;
            int ge = sample7(ew, s), gc = sample7(cw, s);
            samples++;
            if (ge != x[0] || gc != x[1]) {
              if (bad + seg_bad < 10)
                fprintf(stderr, "seg %u row %d col %d: err %d/%d corr %d/%d\n",
                        id, row, col, ge, x[0], gc, x[1]);
              seg_bad++;
            }
          }
        }
        // a chroma output: two columns of U and V of row out_c_row of strip
        // out_c_strip; every checked sample must appear exactly once
        if (chroma && dut->out_c_valid) {
          const int r = dut->out_c_row, s = dut->out_c_strip;
          const uint64_t y = dut->out_c_y;
          for (int pl = 0; pl < 2; pl++) {
            if (!((cchk >> pl) & 1)) continue;
            for (int j = 0; j < 2; j++) {
              const int x = 2 * s - 4 + j;
              if (x < 0 || x >= WC || r >= chh) continue;
              const size_t k = ((size_t)pl * chh + r) * WC + x;
              const int got = (int)((y >> (20 * pl + 10 * j)) & 0x3FF), want = cexp[k];
              cseen[k]++;
              chroma_samples++;
              if (got != want) {
                if (bad + seg_bad < 10)
                  fprintf(stderr, "seg %u chroma plane %d row %d col %d: %d/%d\n", id, pl, r, x, got, want);
                seg_bad++;
              }
            }
          }
        }
        pdump();
        dut->clk = 1; dut->eval(); dump(1); cycles++;
        // the input advances on a handshake; the segment ends when all words
        // and in-segment writes are in and the core is idle again
        if (take) ip++;
        if (!dut->busy && ip >= nw && sw >= sw_at.size()) break;
        if (++guard > 1000000) { fprintf(stderr, "timeout seg %u\n", id); return 2; }
      }
      dut->cfg_we = 0;
      seg_writes += sw_at.size();
      sw_at.clear(); sw_addr.clear(); sw_data.clear();
      // completeness: every group, class block and chroma sample was output
      if (chk_gdf || chk_y)
        for (size_t i = 0; i < seen.size(); i++)
          if (!seen[i]) { seg_bad++; if (bad + seg_bad < 10) fprintf(stderr, "seg %u missing group %zu\n", id, i); }
      for (size_t i = 0; i < pseen.size(); i++)
        if (!pseen[i]) { seg_bad++; if (bad + seg_bad < 10) fprintf(stderr, "seg %u missing block %zu\n", id, i); }
      for (size_t k = 0; k < cseen.size(); k++)
        if (((cchk >> (k / ((size_t)chh * WC))) & 1) && cseen[k] != 1) {
          seg_bad++;
          if (bad + seg_bad < 10) fprintf(stderr, "seg %u chroma sample %zu seen %d times\n", id, k, cseen[k]);
        }
      bad += seg_bad;
      seg_cycles_total += cycles - c0;
      segs++;
      if (verbose) printf("seg %u %ux%u: %llu cycles, %llu bad\n", id, H, W,
                          (unsigned long long)(cycles - c0), (unsigned long long)seg_bad);
    } else if (type == 6) {
      // chroma LR segment (CH = 1, tools/make_lrc_vectors.py): luma words in
      // column-major order, one chroma word per luma word (main row p-1,
      // extra rows -2 / H/2+1 at p = 0 / H/2+1), U and V outputs checked
      uint16_t H, W, NCH, WC; uint32_t id; uint8_t chk;
      rd(f, &H); rd(f, &W); rd(f, &NCH); rd(f, &id); rd(f, &WC); rd(f, &chk);
      const int hh = H / 2, npairs = (H + 4) / 2;
      std::vector<uint16_t> lum((size_t)npairs * NCH * 8), chr((size_t)2 * (hh + 4) * 2 * NCH),
          cexp((size_t)2 * hh * WC);
      std::vector<uint8_t> side(NCH);
      if (fread(lum.data(), 2, lum.size(), f) != lum.size() ||
          fread(chr.data(), 2, chr.size(), f) != chr.size() ||
          fread(side.data(), 1, side.size(), f) != side.size() ||
          fread(cexp.data(), 2, cexp.size(), f) != cexp.size()) {
        fprintf(stderr, "truncated chroma segment %u\n", id); return 2;
      }
      if (!vs || NB != 1 || GC != 4) { fprintf(stderr, "chroma segments need VS=1 NB=1 GC=4\n"); return 2; }
      auto C = [&](int pl, int row, int col) -> uint32_t {   // row -2.., column -4..
        return chr[((size_t)pl * (hh + 4) + (row + 2)) * 2 * NCH + (col + 4)] & 0x3FF;
      };
      auto crow = [&](int row, int c) -> uint64_t {          // {V1, V0, U1, U0}
        return (uint64_t)C(0, row, 2 * c - 4) | ((uint64_t)C(0, row, 2 * c - 3) << 10) |
               ((uint64_t)C(1, row, 2 * c - 4) << 20) | ((uint64_t)C(1, row, 2 * c - 3) << 30);
      };
      std::vector<uint8_t> cseen(cexp.size(), 0);
      dut->seg_h = H; dut->seg_nch = NCH; dut->seg_start = 1;
      tick();
      dut->seg_start = 0;
      const size_t nw = (size_t)NCH * (hh + 2);
      size_t ip = 0;
      uint64_t c0 = cycles, seg_bad = 0;
      int guard = 0;
      for (;;) {
        if (ip < nw) {
          const int c = (int)(ip / (hh + 2)), p = (int)(ip % (hh + 2));
          uint32_t w[6] = {0, 0, 0, 0, 0, 0};
          for (int s = 0; s < 8; s++) {
            const uint32_t v = lum[((size_t)p * NCH + c) * 8 + s] & 0x3FF;
            const int bit = 10 * s;
            w[bit / 32] |= v << (bit % 32);
            if (bit % 32 > 22) w[bit / 32 + 1] |= v >> (32 - bit % 32);
          }
          put(dut->in_data, w);
          const uint64_t mr = crow(p - 1, c);
          const uint64_t er = (p == 0) ? crow(-2, c) : (p == hh + 1) ? crow(hh + 1, c) : 0;
          uint32_t cw[3] = {(uint32_t)mr, (uint32_t)(mr >> 32) | (uint32_t)(er << 8),
                            (uint32_t)(er >> 24)};
          put(dut->in_c_data, cw);
          dut->in_c_lr = side[c];
          dut->in_tskip = 0; dut->in_lr = 0; dut->in_gdf = 1; dut->in_valid = 1;
        } else {
          dut->in_valid = 0; dut->in_tskip = 0; dut->in_lr = 0;
        }
        dut->cfg_we = 0;
        dut->clk = 0; dut->eval(); dump(0);
        const bool take = dut->in_valid && dut->in_ready;
        if (dut->out_c_valid) {
          const int r = dut->out_c_row, s = dut->out_c_strip;
          const uint64_t y = dut->out_c_y;
          for (int pl = 0; pl < 2; pl++) {
            if (!((chk >> pl) & 1)) continue;
            for (int j = 0; j < 2; j++) {
              const int x = 2 * s - 4 + j;
              if (x < 0 || x >= WC || r >= hh) continue;
              const size_t k = ((size_t)pl * hh + r) * WC + x;
              const int got = (int)((y >> (20 * pl + 10 * j)) & 0x3FF), want = cexp[k];
              cseen[k]++;
              lr_samples++;
              if (got != want) {
                if (bad + seg_bad < 10)
                  fprintf(stderr, "chroma seg %u plane %d row %d col %d: %d/%d\n", id, pl, r, x, got, want);
                seg_bad++;
              }
            }
          }
        }
        pdump();
        dut->clk = 1; dut->eval(); dump(1); cycles++;
        // (type 6: luma and chroma words only, the chroma outputs are checked)
        if (take) ip++;
        if (!dut->busy && ip >= nw) break;
        if (++guard > 1000000) { fprintf(stderr, "timeout chroma seg %u\n", id); return 2; }
      }
      for (size_t k = 0; k < cseen.size(); k++)
        if (((chk >> (k / ((size_t)hh * WC))) & 1) && cseen[k] != 1) {
          seg_bad++;
          if (bad + seg_bad < 10) fprintf(stderr, "chroma seg %u sample %zu seen %d times\n", id, k, cseen[k]);
        }
      bad += seg_bad;
      seg_cycles_total += cycles - c0;
      segs++;
      if (verbose) printf("chroma seg %u %ux%u: %llu cycles, %llu bad\n", id, H, W,
                          (unsigned long long)(cycles - c0), (unsigned long long)seg_bad);
    } else {
      fprintf(stderr, "unknown record %u\n", type); return 2;
    }
  }
  // summary line (parsed by the regression scripts)
  std::string extra;
  if (pcw_blocks) extra += "PC-Wiener blocks checked " + std::to_string(pcw_blocks) + ", ";
  if (lr_samples) extra += "restored samples checked " + std::to_string(lr_samples) + ", ";
  if (chroma_samples) extra += "chroma samples checked " + std::to_string(chroma_samples) + ", ";
  if (seg_writes) extra += "in-segment writes " + std::to_string(seg_writes) + ", ";
  printf("segments %llu, samples checked %llu, %smismatches %llu, cfg writes %llu, "
         "segment cycles %llu\n",
         (unsigned long long)segs, (unsigned long long)samples, extra.c_str(),
         (unsigned long long)bad, (unsigned long long)cfg_writes,
         (unsigned long long)seg_cycles_total);
#if VM_TRACE
  if (tfp) { tfp->close(); delete tfp; }
#endif
  if (pdf) {
    fclose(pdf);
    if (pof) fclose(pof);
    if (pcf) fclose(pcf);
    if (pcof) fclose(pcof);
    FILE* wf = fopen((std::string(pdn) + ".win").c_str(), "w");
    if (wf) {
      fprintf(wf, "%ld %ld %llu\n", pd_win, trace_len, (unsigned long long)pd_lines);
      fclose(wf);
    }
    printf("port dump: %llu edges, window from edge %ld, %ld edges\n",
           (unsigned long long)pd_lines, pd_win, trace_len);
  }
  delete dut;
  return bad ? 1 : 0;
}
