`default_nettype none
// ----------------------------------------------------------------------------
// registered signed multiplier: STG = 2 pipeline stages (DSP48 MREG + PREG,
// FPGA) or STG = 1 (output register only, ASIC)
// ----------------------------------------------------------------------------
(* use_dsp = "yes" *)
module gdf_mul #(
  parameter AWD = 10,
  parameter BWD = 10,
  parameter STG = 2
)(
  input  wire                       clk,
  input  wire signed [AWD-1:0]      a,
  input  wire signed [BWD-1:0]      b,
  output reg  signed [AWD+BWD-1:0]  p
);
  generate
    if (STG == 2) begin : g_two
      reg signed [AWD+BWD-1:0] m;
      always @(posedge clk) begin m <= a * b; p <= m; end
    end else begin : g_one
      always @(posedge clk) p <= a * b;
    end
  endgenerate
endmodule

// ----------------------------------------------------------------------------
// fast-inner-product multiplier: p = (fa + wb) * bq, 11 x 11 bit, where the
// caller supplies the registered second pre-addition bq = fb + wa (fabric).
// Stage 1: the pre-addition fa + wb (DSP48 pre-adder); then STG multiplier
// stages.  22-bit wrap-around result.
// ----------------------------------------------------------------------------
(* use_dsp = "yes" *)
module gdf_mulpre #(
  parameter STG = 2
)(
  input  wire               clk,
  input  wire signed [9:0]  fa,
  input  wire signed [9:0]  wb,
  input  wire signed [10:0] bq,           // registered fb + wa, aligned with ad
  output reg  signed [21:0] p
);
  reg signed [10:0] ad;
  always @(posedge clk) ad <= fa + wb;
  generate
    if (STG == 2) begin : g_two
      reg signed [21:0] m;
      always @(posedge clk) begin m <= ad * bq; p <= m; end
    end else begin : g_one
      always @(posedge clk) p <= ad * bq;
    end
  endgenerate
endmodule

// ----------------------------------------------------------------------------
// simple dual-port RAM (1 read, 1 write), synchronous read
// (line-buffer slot; BRAM/LUTRAM on FPGA, SRAM macro in ASIC)
// ----------------------------------------------------------------------------
module gdf_ram_sdp #(
  parameter W    = 80,
  parameter D    = 32,
  parameter AW   = 5,
  parameter OREG = 0                   // 1: output register (BRAM DOB_REG)
)(
  input  wire          clk,
  input  wire          re,
  input  wire [AW-1:0] ra,
  output wire [W-1:0]  rq,
  input  wire          we,
  input  wire [AW-1:0] wa,
  input  wire [W-1:0]  wd
);
  reg [W-1:0] mem [0:D-1];
  reg [W-1:0] q1, q2;
  always @(posedge clk) begin
    if (re) q1 <= mem[ra];
    if (we) mem[wa] <= wd;
    q2 <= q1;
  end
  assign rq = OREG ? q2 : q1;
endmodule

// ----------------------------------------------------------------------------
// expected-error table: 4096 x 7 bit, one write/read port + one read port,
// two-cycle read latency (BRAM output register)
// ----------------------------------------------------------------------------
module gdf_ram_lut (
  input  wire        clk,
  input  wire        we,
  input  wire [11:0] wa,
  input  wire [6:0]  wd,
  input  wire [11:0] ra0,
  input  wire [11:0] ra1,
  output reg  [6:0]  q0,
  output reg  [6:0]  q1
);
  reg [6:0] mem [0:4095];
  reg [6:0] l0, l1;
  always @(posedge clk) begin
    if (we) mem[wa] <= wd;
    else    l0 <= mem[ra0];
  end
  always @(posedge clk) l1 <= mem[ra1];
  always @(posedge clk) begin q0 <= l0; q1 <= l1; end
endmodule

// ----------------------------------------------------------------------------
// PC-Wiener class ROM: pc_wiener_lut_to_class_index of AV2 (4096 x 8 bit,
// tools/make_pcw_rom.py), synchronous read
// ----------------------------------------------------------------------------
module gdf_rom_pcw #(
  parameter FILE = "pcw_class.hex"
)(
  input  wire        clk,
  input  wire [11:0] a,
  output reg  [7:0]  q
);
  reg [7:0] mem [0:4095];
  initial $readmemh(FILE, mem);
  always @(posedge clk) q <= mem[a];
endmodule

// ----------------------------------------------------------------------------
// LR filter selector ROM: pc_wiener_sub_classify_to_64 of the four quantizer
// sets of AV2 (1024 x 6 bit, address {set, class}, tools/make_pcw_rom.py),
// synchronous read.  Every Wiener-NS sub-classifier (2..16 classes) is a
// function of this 64-filter index, so both LR modes address one 64-entry
// coefficient memory with it.
// ----------------------------------------------------------------------------
module gdf_rom_sel #(
  parameter FILE = "pcw_sel.hex",
  parameter OREG = 0                    // 1: output register (FPGA BRAM DOA_REG)
)(
  input  wire        clk,
  input  wire [9:0]  a,
  output wire [5:0]  q
);
  reg [5:0] mem [0:1023];
  reg [5:0] q1, q2;
  initial $readmemh(FILE, mem);
  always @(posedge clk) begin
    q1 <= mem[a];
    q2 <= q1;
  end
  assign q = OREG ? q2 : q1;
endmodule

// ----------------------------------------------------------------------------
// PC-Wiener classifier of AV2 loop restoration (luma) on the shared front end
// of the column-major GDF core (NB = 1, GC = 4).  The 6x6 feature window of
// the 4x4 block k (rows 4k..4k+3) of group g is the 3x3 of odd-aligned 2x2
// Laplacian cells: the lower cell rows of bands 2k-1, 2k, 2k+1 x cell columns
// 0..2, complete at the odd band 2k+1 (stage 3 of its token).  The samples
// are normalised to 10 bit, so Round2(acc*norm, 2) is the AVM feature for 8-
// and 10-bit video.  The class leaves aligned with the output token.
// ----------------------------------------------------------------------------
module gdf_pcw #(
  parameter AW   = 5,
  parameter NTOK = 24,                 // output token stage of the core
  parameter CPR  = 3,                  // group g = chunk column - CPR
  parameter MSTG = 2,                  // product stages (2: DSP48 AREG/MREG, 1: ASIC)
  parameter FILE = "pcw_class.hex"
)(
  input  wire          clk,
  input  wire [9*13-1:0] cup,          // stage 3: lower cells of band b-1,
  input  wire [9*13-1:0] clo,          //   of band b; [(col*3 + f-1)*13 +: 13]
  input  wire [5:0]    vp,             // cycle in pass (pair) of the word read
  input  wire [AW:0]   vc,             // chunk column of the word read
  input  wire [AW:0]   nch_m1,
  input  wire [5:0]    hh,             // H/2
  input  wire          in_tskip,       // flag of MI (m, c-2) with pair 2m+1
  input  wire          tsz,            // tskip feature is zero
  input  wire          cfg_we,
  input  wire [12:0]   cfg_addr,
  input  wire [15:0]   cfg_wdata,
  input  wire [15:0]   pq_lo,          // low half of a table word
  output reg  [7:0]    cls,
  output wire [7:0]    cls_early       // the class at stage 7 + MSTG (LR filter)
);
  // clip(Round2Signed(t, 14), 0, 255) >> 5
  function [2:0] pq3; input signed [30:0] t;
    reg [30:0] r;
    begin
      r = t + 31'sd8192;
      if (t <= 0) pq3 = 3'd0;
      else pq3 = (r[30:14] > 17'd255) ? 3'd7 : r[21:19];
    end
  endfunction
  function [5:0] tsrow;                  // column weights 1, 4, 1, clamped
    input [2:0] r; input le, re;
    begin
      tsrow = {5'd0, le ? r[1] : r[0]} + {3'd0, r[1], 2'b00} + {5'd0, re ? r[1] : r[2]};
    end
  endfunction

  // ---- transform-skip window.  At t+1 the word of pair p = 2m+1 (first pair
  //      of MI row m) has been read with the flag of MI (m, g+1), and block
  //      k = m-1 (band 2k+1 = p-2) is announced.  The flags of MI columns g-1,
  //      g of every MI row come from the two previous passes; rows and columns
  //      are clamped to the stripe and to the 64-column processing unit.
  reg         ts_d;
  reg  [5:0]  vp_d;
  reg  [AW:0] vc_d;
  always @(posedge clk) begin
    ts_d <= in_tskip;
    vp_d <= vp;
    vc_d <= vc;
  end
  reg  [1:0]  tsb [0:16];                // per MI row: flags of columns {g, g-1}
  reg  [2:0]  tr0, tr1;                  // {g+1, g, g-1} of MI rows m-1, m-2
  wire [4:0]  mr    = vp_d[5:1];         // MI row of the pair
  wire [2:0]  trip  = {ts_d, tsb[mr]};   // MI row m
  wire [AW:0] gg    = vc_d - CPR;
  wire        ledge = (gg[3:0] == 4'd0);
  wire        redge = (gg[3:0] == 4'd15) || (vc_d == nch_m1);
  wire [4:0]  mil   = hh[5:1] - {4'd0, ~hh[0]};              // ceil(H/4) - 1
  wire [2:0]  ra    = (mr == 5'd1) ? tr0 : tr1;              // MI row k-1, clamped
  wire [2:0]  rc    = (mr - 5'd1 == mil) ? tr0 : trip;       // MI row k+1, clamped
  wire [5:0]  tsum_w = tsz ? 6'd0
                     : tsrow(ra, ledge, redge) + {tsrow(tr0, ledge, redge), 2'b00}
                       + tsrow(rc, ledge, redge);
  always @(posedge clk)
    if (vp_d[0]) begin
      tsb[mr] <= {ts_d, tsb[mr][1]};
      tr1     <= tr0;
      tr0     <= trip;
    end
  reg  [5:0]  tsq0, tsq1, tsq2, tsq3;    // to stage 3 (table address), 0..36
  always @(posedge clk) begin
    tsq0 <= tsum_w; tsq1 <= tsq0; tsq2 <= tsq1; tsq3 <= tsq2;
  end

  // ---- stage 4: 6x6 feature sums from 3 x 3 cells; MSTG = 2 (FPGA) keeps
  //      the 3-cell sum of every band (ps1) and of every band pair (ps2), so
  //      that no stage adds more than four terms
  reg  [9*13-1:0] cup2;                  // lower cells of band b-2
  reg  [16:0] pacc [1:3];
  reg  [14:0] ps1 [1:3];                 // MSTG = 2: band b-1
  reg  [15:0] ps2 [1:3];                 // MSTG = 2: bands b-2, b-1
  integer pc, pf;
  reg  [16:0] ps;
  reg  [14:0] pn;
  always @(posedge clk) begin
    cup2 <= cup;
    for (pf = 1; pf <= 3; pf = pf + 1) begin
      ps = 17'd0;
      for (pc = 0; pc < 3; pc = pc + 1)
        ps = ps + cup2[(pc*3 + pf-1)*13 +: 13] + cup[(pc*3 + pf-1)*13 +: 13]
                + clo[(pc*3 + pf-1)*13 +: 13];
      pn = clo[(pf-1)*13 +: 13] + clo[(3 + pf-1)*13 +: 13] + clo[(6 + pf-1)*13 +: 13];
      ps1[pf] <= pn;
      ps2[pf] <= {1'b0, ps1[pf]} + pn;
      if (MSTG == 2)
        pacc[pf] <= {1'b0, ps2[pf]} + pn;
      else
        pacc[pf] <= ps;
    end
  end
  // ---- qval_given_tskip_lut rows (per frame), read at stage 3
  wire [4*26-1:0] ql_b;
  genvar gf;
  generate
    for (gf = 0; gf < 4; gf = gf + 1) begin : g_ql
      gdf_ram_sdp #(.W(26), .D(64), .AW(6)) u_ql (.clk(clk), .re(1'b1), .ra(tsq3),
        .rq(ql_b[gf*26 +: 26]),
        .we(cfg_we && cfg_addr[12:9] == 4'b1111 && cfg_addr[0] && cfg_addr[2:1] == gf),
        .wa(cfg_addr[8:3]), .wd({cfg_wdata[9:0], pq_lo}));
    end
  endgenerate
  // ---- stages 5..4+MSTG: normalisation (constant products; FPGA: operand and
  //      product registers of the DSP slice); + qval; Round2(., 14), clip to
  //      8 bit, 3-bit level; class ROM
  reg  [28:0]        pprod [1:3];
  reg  signed [25:0] qld [0:3];
  reg  signed [30:0] pt  [0:3];
  reg  [11:0]        plut;
  generate
    if (MSTG == 2) begin : g_m2
      reg [16:0] pacc_q [1:3];
      reg signed [25:0] qld0 [0:3];
      integer mf;
      always @(posedge clk) begin
        for (mf = 1; mf < 4; mf = mf + 1) pacc_q[mf] <= pacc[mf];
        for (mf = 0; mf < 4; mf = mf + 1) begin
          qld0[mf] <= ql_b[mf*26 +: 26];
          qld[mf]  <= qld0[mf];
        end
        pprod[1] <= pacc_q[1] * 12'd3739;
        pprod[2] <= pacc_q[2] * 12'd3273;
        pprod[3] <= pacc_q[3] * 12'd3074;
      end
    end else begin : g_m1
      integer mf;
      always @(posedge clk) begin
        for (mf = 0; mf < 4; mf = mf + 1) qld[mf] <= ql_b[mf*26 +: 26];
        pprod[1] <= pacc[1] * 12'd3739;  // SCALE_LUMA(5384)
        pprod[2] <= pacc[2] * 12'd3273;  // SCALE_LUMA(4713)
        pprod[3] <= pacc[3] * 12'd3074;  // SCALE_LUMA(4426)
      end
    end
  endgenerate
  integer tf;
  always @(posedge clk) begin
    pt[0] <= {{5{qld[0][25]}}, qld[0]};
    for (tf = 1; tf < 4; tf = tf + 1)
      pt[tf] <= $signed({4'd0, pprod[tf][28:2]} + {29'd0, pprod[tf][1]})
              + $signed({{5{qld[tf][25]}}, qld[tf]});
    plut <= {pq3(pt[0]), pq3(pt[1]), pq3(pt[2]), pq3(pt[3])};
  end
  wire [7:0] pcls;                       // stage 7 + MSTG
  gdf_rom_pcw #(.FILE(FILE)) u_pcr (.clk(clk), .a(plut), .q(pcls));
  assign cls_early = pcls;
  // ---- align with the output token (tok[NTOK-1])
  localparam PDL = NTOK - 11 - MSTG;
  reg  [7:0] pdl [0:PDL];
  integer pi;
  always @(posedge clk) begin
    pdl[0] <= pcls;
    for (pi = 1; pi <= PDL; pi = pi + 1) pdl[pi] <= pdl[pi-1];
    cls <= pdl[PDL];
  end
endmodule

// ============================================================================
// AV2 Guided Detail Filter (GDF) core - stripe-segment engine
//
// Processes one stripe segment of H (<= 64, even) rows x W (even) columns,
// 8 samples per cycle (a group of 2 rows x 4 columns = two 2x2 class blocks;
// VS = 1 also 4 or 16 samples per cycle, see NB and GC).
// Bit-exact with AV2 v1.0.0 section 7.20.5 (see analysis/gdf_hw_model.py).
//
// Input stream: row pairs (rows -2..H+1, i.e. 2 saved lines above/below),
// each row carrying 6 apron columns on both sides (W+12 columns, padded to a
// multiple of 4).  One 80-bit word = 2 rows x 4 samples:
//   [39:0] = upper row, samples 0..3 ; [79:40] = lower row, samples 0..3.
// VS = 0 reads the words row pair by row pair; VS = 1 (column scan) reads
// them strip by strip (for each 4-column chunk, all row pairs top to bottom)
// and keeps only a column buffer of H/2+2 words instead of line buffers.
// Within a segment the core reads one word in every cycle in which in_ready
// is high (read-strobe semantics: in_data must be valid in that cycle; a
// missing word sets the sticky 'underrun' flag).  The datapath therefore has
// no stall logic and no clock enables.
// Output: one group per valid cycle (band/group raster order for VS = 0,
// group/band order for VS = 1); err = expected coding error, corr = scaled
// correction to be added to the loop-restoration output (out = clip(LR +
// corr)).  PCW = 1 adds the PC-Wiener class of loop restoration for every
// 4x4 block (out_pcw), computed on the shared Laplacian cells.  LR = 1 adds
// the loop-restoration filter of AV2 luma (PC-Wiener and Wiener-NS, 16 tap
// pairs within +-4 rows/columns) on the same window, and out_y carries the
// restored samples y = clip(LR + corr) of the joint LR/GDF stage.
//
// Hardware-oriented reformulation (R1..R9, docs/gdf_algorithm_analysis.md):
//  R1 34-slot MAC (V12/H12/M10) + class-parity output swap
//  R2 gradient MACs once per 2x2 block        R4 separable 2x2-cell box sums
//  R5 multiplier-free index quantisation      R6 12-bit concatenated address
//  R7 bias added once                          R8 shift-add compensation
//  R9 8-bit input normalised to 10 bit at the input
// Look-ahead classification: the window holds 8 chunks (VS = 1: 10 row
// pairs); a group's class is computed from the front of the window while its
// samples travel to the back, where the pair differences are formed just in
// time for the class-dependent clipping (no delay line for the 288
// differences per cycle).
// ============================================================================
module gdf_core #(
  parameter MAXCH = 32,          // max 4-column chunks per row (incl. apron)
  parameter AW    = 5,           // clog2(MAXCH)
  parameter FULL  = 0,           // 1: conventional datapath (sets MACF = IDXF = 1)
  parameter MSTG  = 2,           // multiplier pipeline stages (2: FPGA DSP48, 1: ASIC)
  // ablation switches (defaults: proposed design)
  parameter MACF  = FULL,        // 1: 54 spatial MACs/sample + 12 gradient MACs/block,
                                 //    no class swap (0: V12/H12/M10 slots + parity swap)
  parameter IDXF  = FULL,        // 1: per-feature bit-depth shifts, multiplier-based
                                 //    quantisation, address and compensation
  parameter LA    = 1,           // 1: look-ahead classification (8-chunk window)
                                 // 0: 4-chunk window + 5-stage difference delay line
  parameter FIP   = 0,           // 1: fast inner product (requires MACF = 0):
                                 //    15 pre-added + 10 shared feature products per
                                 //    sample, class-dependent 22-bit biases
                                 //    (0x1800 + (cls<<3) + (out<<1) + {lo, hi})
  parameter VS    = 0,           // 1: column-major stripe scan (requires LA = 1):
                                 //    input words chunk-major (for c: for p), a
                                 //    column buffer of H/2+2 words replaces the
                                 //    six width-dependent line buffers
  // parallelism (VS = 1 only; VS = 0 requires NB = 1, GC = 4):
  //   NS = 2*NB*GC samples per cycle, a group of 2*NB rows x GC columns
  parameter NB    = 1,           // row pairs (bands) per cycle: 1 or 2
  parameter GC    = 4,           // columns per group (chunk width): 2 or 4
  // joint loop-restoration front end (VS = 1, NB = 1, GC = 4, IDXF = 0)
  parameter PCW   = 0,           // 1: PC-Wiener classifier of LR on the shared cells
  parameter GDFB  = 1,           // 0: no GDF back end (PC-Wiener-only baseline)
  parameter LR    = 0,           // 1: LR filter back end (requires PCW = 1; stripe
                                 //    heights H multiple of 4)
  parameter CH    = 0,           // 1: chroma LR (gdf_lrc) beside the column scan
                                 //    (VS = 1, NB = 1, GC = 4; H multiple of 4)
  parameter PCWROM = "pcw_class.hex",
  parameter LRSEL  = "pcw_sel.hex"
)(
  input  wire          clk,
  input  wire          rst,
  // configuration bus (write only, while busy is low)
  //   0x0000-0x0FFF LUT entry (7-bit signed)
  //   0x1000 + (cls<<7) + slot   weight (10-bit signed)
  //       proposed: slot V0..11 H12..23 M24..33 (class-parity routed)
  //       MACF    : slot = out*22 + feature (0..65)
  //   0x1400 + (cls<<5) + k      alpha  (9-bit), k = feature 0..21
  //   0x1800 + i                 bias   (16-bit signed), i = 0..2
  //   0x1A00 + (e<<3) + w        LR: coefficient entry e = 0..63 (filter index) of
  //                              the write bank, 16-bit words w = 0..6 of the
  //                              105-bit entry, w = 7 commits: tap k at
  //                              [LOFF(k) +: LW(k)] (signed), centre tap at
  //                              [104:95] (signed); may be written while busy
  //                              (a bank that the stream does not use)
  //   0x1C00                     mode {LR set [8:7], LR on [6], GDF on [5],
  //                              tskip_zero [4], s_pic-1 [3:2], bd10 [1], intra [0]}
  //   0x1C01                     LR: write bank (0..3) of the coefficient memory
  //   0x1E00 + (t<<3) + (f<<1) + {lo, hi}  PCW: qval_given_tskip_lut[7t][f]
  //                              (26-bit signed, t = 0..36, f = 0..3; hi commits)
  input  wire          cfg_we,
  input  wire [12:0]   cfg_addr,
  input  wire [15:0]   cfg_wdata,
  // segment control
  input  wire          seg_start,
  input  wire [6:0]    seg_h,        // rows H (even, 2..64)
  input  wire [AW:0]   seg_nch,      // chunks per row = ceil((W+12)/GC) >= 16/GC
  output wire          busy,
  // input stream: one word = NB row pairs x GC samples, sample (pair n,
  // row r, column x) at [10*((2n+r)*GC+x) +: 10]
  input  wire          in_valid,
  output wire          in_ready,
  input  wire [20*NB*GC-1:0] in_data,
  input  wire          in_tskip,     // PCW: transform-skip flag of MI (m, c-2),
                                     // valid with the word of row pair 2m+1
  input  wire [2:0]    in_lr,        // LR: {LR on, coefficient bank} of the
                                     // restoration unit of group c - 12/GC,
                                     // valid with every word of chunk c
  input  wire          in_gdf,       // GDF on in the block of group c - 12/GC
                                     // (block flag and local mode of AV2; 1 if
                                     // unused), valid with every word of chunk
                                     // c (VS = 1): out_err and out_corr are 0
                                     // where it is off
  output reg           underrun,     // sticky: in_ready without in_valid
  // output stream: first band of the group, group index
  output wire          out_valid,
  output wire [5:0]    out_band,
  output wire [AW-1:0] out_group,
  output reg  [14*NB*GC-1:0] out_err,   // NS x 7-bit signed, sample s at [7s+:7]
  output reg  [14*NB*GC-1:0] out_corr,  // s = row*GC + col, row 0..2*NB-1
  output reg  [7:0]    out_pcw,      // PCW: class of 4x4 block (band/2, group),
                                     // valid with out_valid for odd bands
  output reg  [10*NB*GC*2-1:0] out_y, // LR: restored samples clip(LR + corr), native
                                     // bit depth, sample s at [10s +: 10]
  // CH: chroma LR, one chroma word per input word (gdf_lrc): main row p-1
  // [39:0] and extra row [79:40] (row -2 at p = 0, row H/2+1 at p = H/2+1),
  // each {V col 1, V col 0, U col 1, U col 0} of chroma strip c (columns
  // 2c-4, 2c-3), native bit depth; side info of strip c {V on, V bank, U on,
  // U bank}; output row out_c_row of strip out_c_strip (columns 2s-4, 2s-3)
  input  wire [79:0]   in_c_data,
  input  wire [5:0]    in_c_lr,
  output wire          out_c_valid,
  output wire [5:0]    out_c_row,
  output wire [AW:0]   out_c_strip,
  output wire [39:0]   out_c_y
);

  // --------------------------------------------------------------------------
  // constant tables
  // --------------------------------------------------------------------------
  // neighbour offsets (dy, dx) of the 18 point-symmetric pair features
  function integer FDY; input integer k;
    begin
      case (k)
        0: FDY = 6; 1: FDY = 5; 2: FDY = 4; 3: FDY = 3;
        4, 5, 6: FDY = 2;
        7, 8, 9, 10, 11: FDY = 1;
        default: FDY = 0;
      endcase
    end
  endfunction
  function integer FDX; input integer k;
    begin
      case (k)
        0, 1, 2, 3, 5, 9: FDX = 0;
        4: FDX = 1;   6: FDX = -1;  7: FDX = 2;  8: FDX = 1;
        10: FDX = -1; 11: FDX = -2; 12: FDX = 6; 13: FDX = 5;
        14: FDX = 4;  15: FDX = 3;  16: FDX = 2; default: FDX = 1;
      endcase
    end
  endfunction
  // feature index of the MAC slots (R1)
  function integer VF; input integer i;      // V sub-filter, 12 slots
    begin
      case (i)
        0: VF = 0; 1: VF = 1; 2: VF = 2; 3: VF = 3; 4: VF = 4; 5: VF = 5;
        6: VF = 6; 7: VF = 8; 8: VF = 9; 9: VF = 10; 10: VF = 16; default: VF = 17;
      endcase
    end
  endfunction
  function integer HF; input integer i;      // H sub-filter, 12 slots
    begin
      case (i)
        0: HF = 5; 1: HF = 7; 2: HF = 8; 3: HF = 9; 4: HF = 10; 5: HF = 11;
        6: HF = 12; 7: HF = 13; 8: HF = 14; 9: HF = 15; 10: HF = 16; default: HF = 17;
      endcase
    end
  endfunction
  function integer MF; input integer i;      // M sub-filter, 6 spatial slots
    begin
      case (i)
        0: MF = 3; 1: MF = 5; 2: MF = 9; 3: MF = 15; 4: MF = 16; default: MF = 17;
      endcase
    end
  endfunction
  // slot of a feature in the V / H / M arrays (inverse of VF / HF / MF)
  function integer VSLOT; input integer f;
    begin
      case (f)
        0: VSLOT = 0; 1: VSLOT = 1; 2: VSLOT = 2; 3: VSLOT = 3; 4: VSLOT = 4; 5: VSLOT = 5;
        6: VSLOT = 6; 8: VSLOT = 7; 9: VSLOT = 8; 10: VSLOT = 9; 16: VSLOT = 10; default: VSLOT = 11;
      endcase
    end
  endfunction
  function integer HSLOT; input integer f;
    begin
      case (f)
        5: HSLOT = 0; 7: HSLOT = 1; 8: HSLOT = 2; 9: HSLOT = 3; 10: HSLOT = 4; 11: HSLOT = 5;
        12: HSLOT = 6; 13: HSLOT = 7; 14: HSLOT = 8; 15: HSLOT = 9; 16: HSLOT = 10; default: HSLOT = 11;
      endcase
    end
  endfunction
  function integer MSLOT; input integer f;
    begin
      case (f)
        3: MSLOT = 0; 5: MSLOT = 1; 9: MSLOT = 2; 15: MSLOT = 3; 16: MSLOT = 4; default: MSLOT = 5;
      endcase
    end
  endfunction
  // fast inner product (FIP): feature pairs of the ten shared feature products
  // (a minimum: V and H can share at most three pairs, and the M pair holding
  // feature 3 cannot be shared) and their use by the V, H and M sub-filters
  function integer FFA; input integer j;
    begin
      case (j)
        0: FFA = 5; 1: FFA = 16; 2: FFA = 8; 3: FFA = 0; 4: FFA = 2;
        5: FFA = 4; 6: FFA = 7; 7: FFA = 12; 8: FFA = 14; default: FFA = 3;
      endcase
    end
  endfunction
  function integer FFB; input integer j;
    begin
      case (j)
        0: FFB = 9; 1: FFB = 17; 2: FFB = 10; 3: FFB = 1; 4: FFB = 3;
        5: FFB = 6; 6: FFB = 11; 7: FFB = 13; 8: FFB = 15; default: FFB = 15;
      endcase
    end
  endfunction
  function integer VFF; input integer j;     // V pair j -> shared product
    begin VFF = j; end
  endfunction
  function integer HFF; input integer j;     // H pairs: 0, 1, 2, 6, 7, 8
    begin HFF = (j < 3) ? j : j + 3; end
  endfunction
  function integer MFF; input integer j;     // M pairs: 0, 1, 9
    begin MFF = (j < 2) ? j : 9; end
  endfunction
  // PC-Wiener: Laplacian direction of feature f1 (|V|), f2 (|D1|), f3 (|D0|)
  function integer PCWD; input integer f;
    begin PCWD = (f == 1) ? 0 : ((f == 2) ? 3 : 2); end
  endfunction
  // LR: (row, column) of one sample of each of the 16 point-symmetric tap
  // pairs of AV2 luma (Wiener-NS order; PC-Wiener uses pairs 0..11)
  function integer LDR; input integer k;
    begin
      case (k)
        0: LDR = 1;  1: LDR = 0;  2: LDR = 2;  3: LDR = 0;  4: LDR = 1;  5: LDR = -1;
        6: LDR = 2;  7: LDR = 2;  8: LDR = 1;  9: LDR = 1;  10: LDR = 3; 11: LDR = 0;
        12: LDR = 4; 13: LDR = 0; default: LDR = 3;
      endcase
    end
  endfunction
  function integer LDC; input integer k;
    begin
      case (k)
        0: LDC = 0;  1: LDC = 1;  2: LDC = 0;  3: LDC = 2;  4: LDC = 1;  5: LDC = 1;
        6: LDC = 1;  7: LDC = -1; 8: LDC = 2;  9: LDC = -2; 10: LDC = 0; 11: LDC = 3;
        12: LDC = 0; 13: LDC = 4; 14: LDC = 3; default: LDC = -3;
      endcase
    end
  endfunction
  // LR: coefficient width of tap k, the exact range of the four PC-Wiener
  // banks and of the Wiener-NS syntax (taps 0..11: 8 8 7 6 7 7 6 7 6 6 5 6
  // bit, taps 12..15: 4 bit), and its offset in the 105-bit coefficient entry
  // (centre tap, 10 bit, at 95)
  function integer LW; input integer k;
    begin
      case (k)
        0, 1: LW = 8;  2, 4, 5, 7: LW = 7;  10: LW = 5;  12, 13, 14, 15: LW = 4;
        default: LW = 6;
      endcase
    end
  endfunction
  function integer LOFF; input integer k;
    begin
      case (k)
        0: LOFF = 0;   1: LOFF = 8;   2: LOFF = 16;  3: LOFF = 23;  4: LOFF = 29;
        5: LOFF = 36;  6: LOFF = 43;  7: LOFF = 49;  8: LOFF = 56;  9: LOFF = 62;
        10: LOFF = 68; 11: LOFF = 73; 12: LOFF = 79; 13: LOFF = 83; 14: LOFF = 87;
        15: LOFF = 91; default: LOFF = 95;
      endcase
    end
  endfunction

  // --------------------------------------------------------------------------
  // configuration registers
  // --------------------------------------------------------------------------
  localparam WS = MACF ? 66 : 34;             // weight slots per class
  reg [WS*10-1:0] wbus0, wbus1, wbus2, wbus3; // 10-bit weights per class
  reg [197:0] abus0, abus1, abus2, abus3;     // 22 x 9-bit alphas per class
  reg [15:0]  bias0, bias1, bias2;
  reg [21:0]  cbias [0:3][0:2];               // FIP: bias per class and output
  integer cbc, cbo;
  reg         intra_r, bd10_r;
  reg [1:0]   spic_r;                         // s_pic - 1
  reg         tsz_r;                          // PCW: transform-skip feature is 0
  reg [15:0]  pq_lo;                          // PCW: table word, low half
  reg         gdfon_r, lron_r;                // LR: GDF / LR applied to out_y
  reg [1:0]   lrset_r;                        // LR: quantizer set of the filters
  reg [1:0]   lwb_r;                          // LR: coefficient write bank
  reg [111:0] lcs;                            // LR: coefficient entry, words 0..6
  wire        lc_we = cfg_we && cfg_addr[12:9] == 4'b1101 && cfg_addr[2:0] == 3'd7;

  // one static decoder per register slot (no variable part-selects)
  integer ci;
  always @(posedge clk) begin
    // 0x1000..: weights of class cfg_addr[8:7], slot cfg_addr[6:0]
    if (cfg_we && cfg_addr[12:10] == 3'b100)
      for (ci = 0; ci < WS; ci = ci + 1)
        if (cfg_addr[6:0] == ci)
          case (cfg_addr[8:7])
            2'd0: wbus0[ci*10 +: 10] <= cfg_wdata[9:0];
            2'd1: wbus1[ci*10 +: 10] <= cfg_wdata[9:0];
            2'd2: wbus2[ci*10 +: 10] <= cfg_wdata[9:0];
            default: wbus3[ci*10 +: 10] <= cfg_wdata[9:0];
          endcase
    // 0x1400..: clipping thresholds (alpha) of class cfg_addr[6:5], feature
    // cfg_addr[4:0]
    if (cfg_we && cfg_addr[12:10] == 3'b101)
      for (ci = 0; ci < 22; ci = ci + 1)
        if (cfg_addr[4:0] == ci)
          case (cfg_addr[6:5])
            2'd0: abus0[ci*9 +: 9] <= cfg_wdata[8:0];
            2'd1: abus1[ci*9 +: 9] <= cfg_wdata[8:0];
            2'd2: abus2[ci*9 +: 9] <= cfg_wdata[8:0];
            default: abus3[ci*9 +: 9] <= cfg_wdata[8:0];
          endcase
    // 0x1800..: biases of the three outputs; with the fast inner product one
    // 22-bit bias per class and output (the weight products are folded in),
    // written as a low and a high word
    if (!FIP && cfg_we && cfg_addr[12:9] == 4'b1100)
      case (cfg_addr[1:0])
        2'd0: bias0 <= cfg_wdata;
        2'd1: bias1 <= cfg_wdata;
        default: bias2 <= cfg_wdata;
      endcase
    if (FIP && cfg_we && cfg_addr[12:9] == 4'b1100)
      for (cbc = 0; cbc < 4; cbc = cbc + 1)
        for (cbo = 0; cbo < 3; cbo = cbo + 1)
          if (cfg_addr[4:3] == cbc && cfg_addr[2:1] == cbo) begin
            if (!cfg_addr[0]) cbias[cbc][cbo][15:0]  <= cfg_wdata;
            else              cbias[cbc][cbo][21:16] <= cfg_wdata[5:0];
          end
    // with CH = 1 only 0x1C00 / 0x1C01 (0x1C02.. belong to the chroma LR)
    if (cfg_we && cfg_addr[12:9] == 4'b1110 && !cfg_addr[0]
        && (CH == 0 || cfg_addr[8:1] == 8'd0)) begin
      intra_r <= cfg_wdata[0];
      bd10_r  <= cfg_wdata[1];
      spic_r  <= cfg_wdata[3:2];
      tsz_r   <= cfg_wdata[4];
      gdfon_r <= cfg_wdata[5];
      lron_r  <= cfg_wdata[6];
      lrset_r <= cfg_wdata[8:7];
    end
    if (cfg_we && cfg_addr[12:9] == 4'b1110 && cfg_addr[0]
        && (CH == 0 || cfg_addr[8:1] == 8'd0))
      lwb_r <= cfg_wdata[1:0];                    // LR coefficient write bank
    if (cfg_we && cfg_addr[12:9] == 4'b1111 && !cfg_addr[0])
      pq_lo <= cfg_wdata;                         // PCW table, low half
    if (cfg_we && cfg_addr[12:9] == 4'b1101)      // LR coefficient staging
      for (ci = 0; ci < 7; ci = ci + 1)
        if (cfg_addr[2:0] == ci) lcs[ci*16 +: 16] <= cfg_wdata;
  end

  // --------------------------------------------------------------------------
  // scan order and front end
  //   VS = 0 (row-major): pass k = 0..H/2+3 over the row pairs, chunk j =
  //     0..NCH-1 within a pass, one chunk per cycle; six row-pair line
  //     buffers of NCH words hold the vertical context.  Passes 0..H/2+1 read
  //     input pairs, H/2+2 and H/2+3 are flush passes; band b = k-4 and group
  //     g = j-2 (LA) or j-3 are announced when chunk g+2 (g+3) is read.
  //   VS = 1 (column-major): pass c = 0..NCH-1 over the chunks of GC
  //     columns; within a pass NB row pairs per cycle, pairs p = 0..H/2+1
  //     (rows 2p-2, 2p-1), padded to whole cycles (at least three per pass).
  //     A column buffer holds, for every row pair, the 12 columns left of
  //     chunk c (the horizontal context), so the memory depends on the stripe
  //     height, not on the segment width.  Bands b..b+NB-1 (b = NB*i-2 in
  //     cycle i) and group g = c-12/GC are announced when their last pair is
  //     read; there are no fill or flush cycles: the rows outside the stripe
  //     are substituted in the difference window.
  //   Passes follow each other without gaps in both orders.
  // --------------------------------------------------------------------------
  localparam NS   = 2 * NB * GC;             // samples per cycle (group)
  localparam NBL  = NB * GC / 2;             // 2x2 class blocks per cycle
  localparam IW   = 20 * NB * GC;            // input word bits
  localparam FR   = 12 + 2 * NB;             // difference window rows
  localparam FW   = 12 + GC;                 // difference window columns
  localparam TOKW = 1 + 6 + AW;
  reg              running;
  reg              in_pass;              // an input word is read this cycle
  wire             tok_v;
  wire [5:0]       tok_b;
  wire [AW:0]      tok_g1;
  wire [NS*10-1:0] ylr_a;                // LR output aligned with the output
                                         // stage (native bit depth)
  wire [FR*FW*10-1:0] dsrc_f;            // difference window at stage 5:
                                         // FR rows x FW columns (group at rows
                                         // 6..5+2NB, columns 6..5+GC)
  reg  [14:0]      box [0:NBL-1][0:3];   // stage 4 box sums
  integer bb, bd;
  assign in_ready = in_pass;

  // input normalisation (R9)
  wire [IW-1:0] in_norm;
  genvar gi;
  generate
    for (gi = 0; gi < IW / 10; gi = gi + 1) begin : g_norm
      // IDXF keeps raw samples; the bit-depth shift is applied per feature
      assign in_norm[10*gi +: 10] = (IDXF || bd10_r) ? in_data[10*gi +: 10]
                                                     : {in_data[10*gi +: 8], 2'b00};
    end
  endgenerate
  reg [IW-1:0] in_d;
  always @(posedge clk) in_d <= in_norm;

  // cells: cr 0 = rows 5,6 ; cr 1 = rows 7,8 ; cc 1 = cols 7,8 ; cc 2 = cols 9,10
  function [12:0] cellsum;
    input [16*4*11-1:0] lq; input integer cr; input integer cc; input integer d;
    integer p0, p1, p2, p3;
    begin
      p0 = (2*cr) * 4 + 2*(cc-1);
      p1 = p0 + 1;
      p2 = p0 + 4;
      p3 = p0 + 5;
      cellsum = {2'b00, lq[(p0*4 + d)*11 +: 11]} + {2'b00, lq[(p1*4 + d)*11 +: 11]}
              + {2'b00, lq[(p2*4 + d)*11 +: 11]} + {2'b00, lq[(p3*4 + d)*11 +: 11]};
    end
  endfunction

  // --------------------------------------------------------------------------
  // pipeline schedule (cycles after the window stage W = tok[1]):
  //   1 Laplacian (signed)  2 |.|  3 cells  4 boxes  5 class; differences
  //   6 select  7 feature clip  8 feature sum/sat  9-10 DSP  11-14 adder tree
  //   15 swap+bias  16-18 quantise/address  19-20 LUT  21-22 compensation
  //   (MSTG = 1: every stage after the products one cycle earlier)
  //   MACF: one more adder-tree level (accumulator at stage 16)
  //   IDXF: scale DSP (MSTG stages), round, index, 2 address stages
  // --------------------------------------------------------------------------
  localparam FX   = FIP ? 1 : 0;              // FIP: one pre-addition stage
  localparam ACCS = 15 + MACF - (2 - MSTG) + FX;  // accumulator stage
  localparam LQ   = ACCS + (IDXF ? MSTG + 4 : 3);  // LUT address stage
  localparam NTOK = LQ + 6;
  wire [TOKW-1:0]  tok_in = {tok_v, tok_b, tok_g1[AW-1:0]};
  reg  [TOKW-1:0]  tok [0:NTOK-1];
  integer ti;
  reg any_tok;
  always @(posedge clk) begin
    if (rst) begin
      for (ti = 0; ti < NTOK; ti = ti + 1) tok[ti] <= {TOKW{1'b0}};
    end else begin
      tok[0] <= tok_in;
      for (ti = 1; ti < NTOK; ti = ti + 1) tok[ti] <= tok[ti-1];
    end
  end
  // LR: {LR on, coefficient bank} of the group of every token
  reg  [2:0]       ltk [0:NTOK-1];
  always @(posedge clk) begin
    ltk[0] <= in_lr;
    for (ti = 1; ti < NTOK; ti = ti + 1) ltk[ti] <= ltk[ti-1];
  end
  // GDF on in the block of the group of every token (side stream in_gdf), and
  // for the frame as well (gon), both aligned with the output stage
  reg  [NTOK-2:0]  gtk;
  reg              gon;
  always @(posedge clk) begin
    gtk <= {gtk[NTOK-3:0], in_gdf};
    gon <= gdfon_r && gtk[NTOK-3];
  end
  always @(*) begin
    any_tok = 1'b0;
    for (ti = 0; ti < NTOK; ti = ti + 1) any_tok = any_tok | tok[ti][TOKW-1];
  end
  // chroma LR beside the column scan (vp_x, vc_x: row pair and pass of the
  // input word, set by g_col)
  wire [5:0]  vp_x;
  wire [AW:0] vc_x;
  wire        cbusy;
  generate
    if (CH) begin : g_ch
      gdf_lrc #(.AW(AW), .MSTG(MSTG)) u_lrc (.clk(clk), .rst(rst), .cfg_we(cfg_we),
        .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata), .bd10(bd10_r),
        .seg_start(seg_start && !running), .seg_h(seg_h), .seg_nch(seg_nch),
        .lw(in_pass), .vp(vp_x), .vc(vc_x), .ldata(in_data[79:0]),
        .cdata(in_c_data), .clr(in_c_lr), .oc_valid(out_c_valid),
        .oc_row(out_c_row), .oc_strip(out_c_strip), .oc_y(out_c_y), .cbusy(cbusy));
    end else begin : g_noch
      assign out_c_valid = 1'b0;
      assign out_c_row   = 6'd0;
      assign out_c_strip = {(AW+1){1'b0}};
      assign out_c_y     = 40'd0;
      assign cbusy       = 1'b0;
    end
  endgenerate
  assign busy      = running | any_tok | cbusy;
  assign out_valid = tok[NTOK-1][TOKW-1];
  assign out_band  = tok[NTOK-1][AW +: 6];
  assign out_group = tok[NTOK-1][AW-1:0];

  genvar gp, gd, gr, gn, gy, gz;
  generate
    if (!VS) begin : g_row
      always @(posedge clk) out_pcw <= 8'd0;    // no PC-Wiener classifier
      assign ylr_a = {NS*10{1'b0}};             // no LR filter
      assign vp_x = 6'd0;                       // no chroma LR (CH needs VS)
      assign vc_x = {(AW+1){1'b0}};
      // ------------------------------------------------------------ control
      reg  [AW:0]  nch_m1, nch_m2;          // NCH-1, NCH-2
      reg  [5:0]   lip_r, lp_r;             // last input pass, last pass
      reg  [5:0]   pass;
      reg  [AW:0]  chunk;
      always @(posedge clk) begin
        if (rst) begin
          running  <= 1'b0;
          in_pass  <= 1'b0;
          underrun <= 1'b0;
        end else begin
          // a word must arrive in every cycle of an input pass
          // segment start: last input pass (lip_r) and last pass (lp_r, after
          // the two flush passes) from the stripe height; then chunk by
          // chunk, pass by pass
          if (in_pass && !in_valid) underrun <= 1'b1;
          if (seg_start && !running) begin
            running <= 1'b1;
            in_pass <= 1'b1;
            nch_m1  <= seg_nch - 1'b1;
            nch_m2  <= seg_nch - 2'd2;
            lip_r   <= {1'b0, seg_h[6:1]} + 6'd1;
            lp_r    <= {1'b0, seg_h[6:1]} + 6'd3;
            pass    <= 6'd0;
            chunk   <= {(AW+1){1'b0}};
          end else if (running) begin
            if (chunk == nch_m1) begin
              chunk <= {(AW+1){1'b0}};
              if (pass == lip_r) in_pass <= 1'b0;
              if (pass == lp_r)  running <= 1'b0;
              else               pass    <= pass + 6'd1;
            end else begin
              chunk <= chunk + 1'b1;
            end
          end
        end
      end

      // ------------------------------------------------------------ line buffers
      // 6 row-pair slots, slot 0 oldest; read at t, write back at t+2
      wire [79:0] rq0, rq1, rq2, rq3, rq4, rq5;
      reg  [AW-1:0] wa, wa2;
      reg        first_d, flush_d, wr_pend, wr2;
      wire [AW-1:0] ra = chunk[AW-1:0];
      always @(posedge clk) begin
        wa      <= ra;
        first_d <= (pass == 6'd0);
        flush_d <= !in_pass;
        wr_pend <= running && !rst;
      end
      // incoming pair: input data, or (row H+1, row H+1) during flush passes
      wire [79:0] inc     = flush_d ? {rq5[79:40], rq5[79:40]} : in_d;
      wire [79:0] dup_top = {inc[39:0], inc[39:0]};       // (row -2, row -2)
      // (the same address is read again only in the next pass, NCH >= 4)
      reg [79:0] wd0, wd1, wd2, wd3, wd4, wd5;
      always @(posedge clk) begin
        wd0 <= rq1;
        wd1 <= rq2;
        wd2 <= rq3;
        wd3 <= first_d ? dup_top : rq4;
        wd4 <= first_d ? dup_top : rq5;
        wd5 <= inc;
        wa2 <= wa;
        wr2 <= wr_pend && !rst;
      end
      gdf_ram_sdp #(.W(80), .D(MAXCH), .AW(AW)) u_lb0 (.clk(clk), .re(1'b1), .ra(ra), .rq(rq0),
        .we(wr2), .wa(wa2), .wd(wd0));
      gdf_ram_sdp #(.W(80), .D(MAXCH), .AW(AW)) u_lb1 (.clk(clk), .re(1'b1), .ra(ra), .rq(rq1),
        .we(wr2), .wa(wa2), .wd(wd1));
      gdf_ram_sdp #(.W(80), .D(MAXCH), .AW(AW)) u_lb2 (.clk(clk), .re(1'b1), .ra(ra), .rq(rq2),
        .we(wr2), .wa(wa2), .wd(wd2));
      gdf_ram_sdp #(.W(80), .D(MAXCH), .AW(AW)) u_lb3 (.clk(clk), .re(1'b1), .ra(ra), .rq(rq3),
        .we(wr2), .wa(wa2), .wd(wd3));
      gdf_ram_sdp #(.W(80), .D(MAXCH), .AW(AW)) u_lb4 (.clk(clk), .re(1'b1), .ra(ra), .rq(rq4),
        .we(wr2), .wa(wa2), .wd(wd4));
      gdf_ram_sdp #(.W(80), .D(MAXCH), .AW(AW)) u_lb5 (.clk(clk), .re(1'b1), .ra(ra), .rq(rq5),
        .we(wr2), .wa(wa2), .wd(wd5));
      // 14-row slice, row 0 = oldest (2b-6) ... row 13 = newest (2b+7)
      wire [559:0] slice = {inc, rq5, rq4, rq3, rq2, rq1, rq0};

      // ------------------------------------------------------------ window
      //   LA = 1: 14 rows x 32 columns (8 chunks).  When the class chain of
      //     group g starts (stage W), chunk g+2 is the newest and group column
      //     x sits at window column x+20; five cycles later (stage 5) the group
      //     has moved to window columns x = 0..15, where its pair differences
      //     are formed.
      //   LA = 0: 14 rows x 16 columns (4 chunks); class chain and differences
      //     start from the same window and the differences wait in a delay line.
      localparam WWB = LA ? 320 : 160;
      reg [WWB-1:0] wrow [0:13];
      integer ri;
      always @(posedge clk) begin
        for (ri = 0; ri < 14; ri = ri + 1)
          wrow[ri] <= {slice[40*ri +: 40], wrow[ri][WWB-1:40]};
      end

      // the token of group g enters with chunk g+2 (LA) or g+3 (delay line)
      assign tok_v  = running && (pass >= 6'd4) &&
                      (LA ? (chunk >= 2 && chunk <= nch_m2) : (chunk >= 3));
      assign tok_b  = pass - 6'd4;
      assign tok_g1 = LA ? chunk - 2'd2 : chunk - 2'd3;
      for (gr = 0; gr < 14; gr = gr + 1) begin : g_dsrc
        assign dsrc_f[160*gr +: 160] = wrow[gr][159:0];
      end

      // ------------------------------------------------------------ block unit
      // Laplacians at group rows 5..8, columns 7..10 (LA: window columns +20,
      // the newest six columns); dir 0 V (dy 1, dx 0), 1 H (0, 1), 2 D0 (1, 1),
      // 3 D1 (-1, 1)
      localparam integer LX = LA ? 20 : 0;
      wire [16*4*13-1:0] lraw_w;
      for (gp = 0; gp < 16; gp = gp + 1) begin : g_lap
        localparam integer PR = 5 + gp / 4;
        localparam integer PC = LX + 7 + gp % 4;
        for (gd = 0; gd < 4; gd = gd + 1) begin : g_d
          localparam integer LDY = (gd == 1) ? 0 : ((gd == 3) ? -1 : 1);
          localparam integer LDX = (gd == 0) ? 0 : 1;
          wire [9:0] b = wrow[PR][10*PC +: 10];
          wire [9:0] a = wrow[PR - LDY][10*(PC - LDX) +: 10];
          wire [9:0] c = wrow[PR + LDY][10*(PC + LDX) +: 10];
          assign lraw_w[(gp*4 + gd)*13 +: 13] = {2'b00, b, 1'b0} - {3'b000, a} - {3'b000, c};
        end
      end
      // stage 1: signed 2b-a-c ; stage 2: absolute value
      reg [16*4*13-1:0] lraw_q;
      reg [16*4*11-1:0] lap_q;
      integer lp;
      always @(posedge clk) begin
        lraw_q <= lraw_w;
        for (lp = 0; lp < 64; lp = lp + 1)
          lap_q[lp*11 +: 11] <= lraw_q[lp*13 + 12] ? -lraw_q[lp*13 +: 11]
                                                    :  lraw_q[lp*13 +: 11];
      end
      // stage 3: cells; C0 (cols 5,6) is C2 of the previous cycle (previous group)
      reg [12:0] c0 [0:1][0:3];
      reg [12:0] c1 [0:1][0:3];
      reg [12:0] c2 [0:1][0:3];
      integer cr_i, d_i;
      always @(posedge clk) begin
        for (cr_i = 0; cr_i < 2; cr_i = cr_i + 1)
          for (d_i = 0; d_i < 4; d_i = d_i + 1) begin
            c0[cr_i][d_i] <= c2[cr_i][d_i];
            c1[cr_i][d_i] <= cellsum(lap_q, cr_i, 1, d_i);
            c2[cr_i][d_i] <= cellsum(lap_q, cr_i, 2, d_i);
          end
      end
      // stage 4: boxes, block 0 = cells cc 0,1 ; block 1 = cells cc 1,2
      integer rbd;
      always @(posedge clk) begin
        for (rbd = 0; rbd < 4; rbd = rbd + 1) begin
          box[0][rbd] <= {2'b00, c0[0][rbd]} + {2'b00, c1[0][rbd]}
                       + {2'b00, c0[1][rbd]} + {2'b00, c1[1][rbd]};
          box[1][rbd] <= {2'b00, c1[0][rbd]} + {2'b00, c2[0][rbd]}
                       + {2'b00, c1[1][rbd]} + {2'b00, c2[1][rbd]};
        end
      end
    end else begin : g_col
      // ------------------------------------------------------------ control
      localparam CPR = 12 / GC;              // buffered chunks left of chunk c
      reg  [AW:0]  vc, nch_m1;              // chunk column (pass), NCH-1
      reg  [5:0]   vp, vlp, hh;             // cycle in pass, last cycle, H/2
      assign vp_x = vp;
      assign vc_x = vc;
      always @(posedge clk) begin
        if (rst) begin
          running  <= 1'b0;
          in_pass  <= 1'b0;
          underrun <= 1'b0;
        end else begin
          if (in_pass && !in_valid) underrun <= 1'b1;
          if (seg_start && !running) begin
            running <= 1'b1;
            in_pass <= 1'b1;
            nch_m1  <= seg_nch - 1'b1;
            // ceil((H/2+2)/NB) cycles per pass, at least 3 (column buffer)
            vlp     <= (NB == 1) ? {1'b0, seg_h[6:1]} + 6'd1
                     : ((seg_h[6:1] < 6'd3) ? 6'd2
                                            : {2'b00, seg_h[6:2]} + {5'd0, seg_h[1]});
            hh      <= {1'b0, seg_h[6:1]};
            vc      <= {(AW+1){1'b0}};
            vp      <= 6'd0;
          end else if (running) begin
            if (vp == vlp) begin
              vp <= 6'd0;
              if (vc == nch_m1) begin
                running <= 1'b0;
                in_pass <= 1'b0;
              end else begin
                vc <= vc + 1'b1;
              end
            end else begin
              vp <= vp + 6'd1;
            end
          end
        end
      end

      // ------------------------------------------------------------ column buffer
      // word i = the 12 columns left of chunk c of the NB row pairs of cycle i
      // (per pair 240 b: upper row [119:0], lower row [239:120], oldest column
      // at the LSBs), depth ceil((H/2+2)/NB); read at t, written back at t+2
      // shifted by one chunk (the address is read again in the next pass, at
      // least three cycles later)
      localparam CBW = 240 * NB;
      localparam PW  = 20 * FW;              // bits per row pair in the window
      wire [CBW-1:0]   cq;
      reg  [5:0]       cwa, cwa2;
      reg              cwe, cwe2;
      reg  [CBW-1:0]   cwd;
      wire [NB*PW-1:0] npair;                // the NB new row pairs, FW columns
      for (gn = 0; gn < NB; gn = gn + 1) begin : g_cb
        wire [10*GC-1:0] iu = in_d[(2*gn)*10*GC +: 10*GC];
        wire [10*GC-1:0] il = in_d[(2*gn+1)*10*GC +: 10*GC];
        wire [119:0]     bu = cq[gn*240 +: 120];
        wire [119:0]     bl = cq[gn*240 + 120 +: 120];
        assign npair[gn*PW +: PW] = {il, bl, iu, bu};
        always @(posedge clk)
          cwd[gn*240 +: 240] <= {il, bl[119:10*GC], iu, bu[119:10*GC]};
      end
      always @(posedge clk) begin
        cwa  <= vp;
        cwa2 <= cwa;
        cwe  <= running && !rst;
        cwe2 <= cwe && !rst;
      end
      gdf_ram_sdp #(.W(CBW), .D(34 / NB), .AW(6)) u_cb (.clk(clk), .re(1'b1), .ra(vp),
        .rq(cq), .we(cwe2), .wa(cwa2), .wd(cwd));

      // ------------------------------------------------------------ window
      // vertical shift register of NPV row pairs {lower row, upper row} of FW
      // columns (the 12 buffered columns and chunk c); NB pairs enter per
      // cycle, newest at NPV-1.  At stage W the newest pair is b+NB and the
      // class chains of bands b..b+NB-1 start; at stage 5 the pairs
      // b-3..b+2+NB sit at positions 0..5+NB and form the difference window.
      localparam NPV = 6 * NB + 4;
      reg  [PW-1:0] vwin [0:NPV-1];
      integer vi;
      always @(posedge clk) begin
        for (vi = 0; vi < NPV - NB; vi = vi + 1) vwin[vi] <= vwin[vi + NB];
        for (vi = 0; vi < NB; vi = vi + 1) vwin[NPV - NB + vi] <= npair[vi*PW +: PW];
      end

      assign tok_b  = (NB == 1) ? vp - 6'd2 : {vp[4:0], 1'b0} - 6'd2;
      assign tok_v  = running && (vc >= CPR) && (vp >= ((NB == 1) ? 6'd2 : 6'd1))
                      && (tok_b < hh);
      assign tok_g1 = vc - CPR;

      // difference window: at stage 5 the pairs b-3..b+2+NB at positions
      // 0..5+NB, with the stripe edges substituted in place (AV2 keeps 2 saved
      // rows): pairs above pair -1 (rows -2, -1) repeat row -2 (positions 0, 1
      // for b <= 1), pairs below pair H/2 (rows H, H+1) repeat row H+1
      // (positions >= 5 near the bottom); the selects are registered at stage 4
      localparam RW = 10 * FW;               // bits per row
      wire [5:0]    b4 = tok[5][AW +: 6];
      reg  [FR/2-1:0] abv, blw;
      reg           top1, bot1;
      reg  [1:0]    bsel;                    // H/2 - b near the bottom
      integer si;
      always @(posedge clk) begin
        for (si = 0; si < FR/2; si = si + 1) begin
          abv[si] <= (si <= 1) && ({26'd0, b4} + si <= 1);          // pair b-3+si <= -2
          blw[si] <= (si >= 5) && ({26'd0, b4} + si >= {26'd0, hh} + 4);  // >= H/2+1
        end
        top1 <= (b4 == 6'd0);
        bot1 <= (b4 + 6'd1 == hh);
        bsel <= hh[1:0] - b4[1:0];
      end
      // row -2: upper row of pair -1 (position 2-b); row H+1: lower row of
      // pair H/2 (position H/2+3-b: 4 or 5, and 6 for two bands per cycle)
      wire [RW-1:0] rtop = top1 ? vwin[2][RW-1:0] : vwin[1][RW-1:0];
      wire [RW-1:0] rbot = (NB == 1) ? (bot1 ? vwin[4][PW-1:RW] : vwin[5][PW-1:RW])
                         : (bsel == 2'd1) ? vwin[4][PW-1:RW]
                         : (bsel == 2'd2) ? vwin[5][PW-1:RW] : vwin[6][PW-1:RW];
      for (gr = 0; gr < FR/2; gr = gr + 1) begin : g_dsrc
        assign dsrc_f[2*gr*RW +: RW]     = abv[gr] ? rtop : (blw[gr] ? rbot : vwin[gr][RW-1:0]);
        assign dsrc_f[(2*gr+1)*RW +: RW] = abv[gr] ? rtop : (blw[gr] ? rbot : vwin[gr][PW-1:RW]);
      end

      // ------------------------------------------------------------ block unit
      // band b+n: Laplacians of its lower cell row (rows 2(b+n)+1, 2(b+n)+2,
      // columns 5..4+2*NCC) from pairs b+n and b+n+1; its upper cell row is
      // the lower cell row of band b+n-1 (the same cycle for n > 0, the
      // previous cycle for n = 0), so no Laplacian is computed twice
      localparam NCC = GC / 2 + 1;           // cell columns per band
      localparam NLP = 4 * NCC;              // Laplacian positions per band
      wire [NB*NLP*4*13-1:0] vlraw_w;
      for (gn = 0; gn < NB; gn = gn + 1) begin : g_vb
        // rows 2(b+n) .. 2(b+n)+3 (pair b+n at NPV-1-NB+n)
        wire [2*PW-1:0] lrs = {vwin[NPV-NB+gn], vwin[NPV-1-NB+gn]};
        for (gp = 0; gp < NLP; gp = gp + 1) begin : g_vlap
          localparam integer PR = 1 + gp / (2*NCC);
          localparam integer PC = 5 + gp % (2*NCC);
          for (gd = 0; gd < 4; gd = gd + 1) begin : g_d
            localparam integer LDY = (gd == 1) ? 0 : ((gd == 3) ? -1 : 1);
            localparam integer LDX = (gd == 0) ? 0 : 1;
            wire [9:0] b = lrs[RW*PR + 10*PC +: 10];
            wire [9:0] a = lrs[RW*(PR - LDY) + 10*(PC - LDX) +: 10];
            wire [9:0] c = lrs[RW*(PR + LDY) + 10*(PC + LDX) +: 10];
            assign vlraw_w[((gn*NLP + gp)*4 + gd)*13 +: 13] =
              {2'b00, b, 1'b0} - {3'b000, a} - {3'b000, c};
          end
        end
      end
      // stage 1: signed 2b-a-c ; stage 2: absolute value
      reg [NB*NLP*4*13-1:0] vlraw_q;
      reg [NB*NLP*4*11-1:0] vlap_q;
      integer lp;
      always @(posedge clk) begin
        vlraw_q <= vlraw_w;
        for (lp = 0; lp < NB*NLP*4; lp = lp + 1)
          vlap_q[lp*11 +: 11] <= vlraw_q[lp*13 + 12] ? -vlraw_q[lp*13 +: 11]
                                                      :  vlraw_q[lp*13 +: 11];
      end
      // stage 3: lower cells of each band (columns 5,6 | 7,8 | ...); upc holds
      // the lower cells of the last band of the previous cycle
      reg [12:0] lo  [0:NB-1][0:NCC-1][0:3];
      reg [12:0] upc [0:NCC-1][0:3];
      integer cn, cc_i, d_i;
      always @(posedge clk) begin
        for (cc_i = 0; cc_i < NCC; cc_i = cc_i + 1)
          for (d_i = 0; d_i < 4; d_i = d_i + 1) begin
            upc[cc_i][d_i] <= lo[NB-1][cc_i][d_i];
            for (cn = 0; cn < NB; cn = cn + 1)
              lo[cn][cc_i][d_i] <=
                  {2'b00, vlap_q[((cn*NLP + 2*cc_i)*4 + d_i)*11 +: 11]}
                + {2'b00, vlap_q[((cn*NLP + 2*cc_i + 1)*4 + d_i)*11 +: 11]}
                + {2'b00, vlap_q[((cn*NLP + 2*NCC + 2*cc_i)*4 + d_i)*11 +: 11]}
                + {2'b00, vlap_q[((cn*NLP + 2*NCC + 2*cc_i + 1)*4 + d_i)*11 +: 11]};
          end
      end
      // stage 4: boxes; block j of band n (index n*GC/2 + j) = cell columns j, j+1
      wire [NBL*4*15-1:0] box_n;
      for (gn = 0; gn < NB; gn = gn + 1) begin : g_box
        for (gp = 0; gp < GC/2; gp = gp + 1) begin : g_j
          for (gd = 0; gd < 4; gd = gd + 1) begin : g_d
            wire [12:0] u0, u1;
            if (gn == 0) begin : g_u0
              assign u0 = upc[gp][gd];
              assign u1 = upc[gp+1][gd];
            end else begin : g_un
              assign u0 = lo[gn-1][gp][gd];
              assign u1 = lo[gn-1][gp+1][gd];
            end
            assign box_n[((gn*(GC/2) + gp)*4 + gd)*15 +: 15] =
              {2'b00, u0} + {2'b00, u1} + {2'b00, lo[gn][gp][gd]} + {2'b00, lo[gn][gp+1][gd]};
          end
        end
      end
      integer vbb, vbd;
      always @(posedge clk)
        for (vbb = 0; vbb < NBL; vbb = vbb + 1)
          for (vbd = 0; vbd < 4; vbd = vbd + 1)
            box[vbb][vbd] <= box_n[(vbb*4 + vbd)*15 +: 15];

      // ------------------------------------------------------------ PC-Wiener
      // classifier of LR (AV2 PC-Wiener, luma) on the shared front end (NB = 1,
      // GC = 4).  The 6x6 feature window of the 4x4 block k (rows 4k..4k+3) of
      // group g is the 3x3 of odd-aligned cells: the lower cell rows of bands
      // 2k-1, 2k, 2k+1 x cell columns 0..2, complete at the odd band 2k+1;
      // f1 = |V|, f2 = |D1| (anti-diagonal), f3 = |D0| (diagonal).  The samples
      // are normalised to 10 bit, so Round2(acc*norm, 2) is the AVM feature
      // for 8- and 10-bit video.
      if (PCW) begin : g_pcw
        // cells of the current band (lo) and of the previous band (upc), cell
        // columns 0..2, features f1 = V, f2 = D1, f3 = D0
        wire [9*13-1:0] cup_b, clo_b;
        for (gp = 0; gp < 3; gp = gp + 1) begin : g_c
          for (gd = 0; gd < 3; gd = gd + 1) begin : g_f
            assign cup_b[(gp*3 + gd)*13 +: 13] = upc[gp][PCWD(gd + 1)];
            assign clo_b[(gp*3 + gd)*13 +: 13] = lo[0][gp][PCWD(gd + 1)];
          end
        end
        wire [7:0] pcw_cls, pcw_early;
        gdf_pcw #(.AW(AW), .NTOK(NTOK), .CPR(CPR), .MSTG(MSTG), .FILE(PCWROM)) u_pcw (
          .clk(clk), .cup(cup_b), .clo(clo_b), .vp(vp), .vc(vc), .nch_m1(nch_m1),
          .hh(hh), .in_tskip(in_tskip), .tsz(tsz_r), .cfg_we(cfg_we),
          .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata), .pq_lo(pq_lo), .cls(pcw_cls),
          .cls_early(pcw_early));
        always @(*) out_pcw = pcw_cls;

        // ---------------------------------------------------------- LR filter
        // Loop restoration of AV2 luma (PC-Wiener or Wiener-NS) on the shared
        // window.  The class of 4x4 block k leaves the PC-Wiener unit at stage
        // 7 + MSTG of band 2k+1; its 64-filter index (selector ROM, stage
        // 8 + MSTG) addresses the coefficient memory, which is read only for
        // odd bands, so its registered output holds the filter of block k at
        // stage 11 + MSTG of band 2k and of band 2k+1.  The taps of band b
        // (rows 2b-4..2b+5, group columns -4..+7) are taken at stage TS = 12
        // from an extension of the vertical window by six row pairs: the
        // class latency is hidden by delaying 240-bit row pairs instead of
        // the 1.4-kb tap sums of a group.  The coefficient of tap k has the
        // exact width of the PC-Wiener banks and the Wiener-NS syntax (LW).
        if (LR) begin : g_lr
          localparam SR   = (MSTG == 2) ? 1 : 0;    // FPGA: selector and coefficient
                                                    // memory output registers
          localparam TS   = 12 + 2 * SR;            // tap stage
          localparam LRE  = TS - 6;                 // row pairs below the window
          localparam LLAT = (MSTG == 2) ? 7 : 3;    // tap stage -> ylr_q
          localparam LDL  = 19 + MSTG + FX - TS - LLAT;  // alignment with the output
          wire [5:0]   fsel;                        // stage 8 + MSTG + SR
          gdf_rom_sel #(.FILE(LRSEL), .OREG(SR)) u_sel (.clk(clk),
            .a({lrset_r, pcw_early}), .q(fsel));
          wire         oddf = tok[9 + MSTG + SR][AW];  // band parity at that stage
          wire [104:0] lcoef;                       // stage 9 + MSTG + SR (odd band)
          // four banks of 64 entries: the bank of the restoration unit comes
          // with the group (side stream in_lr), so units change within a
          // stripe while the host writes the next unit into another bank
          wire [1:0]   bank = ltk[9 + MSTG + SR][1:0];
          gdf_ram_sdp #(.W(105), .D(256), .AW(8), .OREG(SR)) u_lc (.clk(clk), .re(oddf),
            .ra({bank, fsel}), .rq(lcoef), .we(lc_we), .wa({lwb_r, cfg_addr[8:3]}),
            .wd(lcs[104:0]));
          reg  [104:0] lcq;                         // stage 11 + MSTG + 2 SR
          always @(posedge clk) lcq <= lcoef;
          // LR on for the frame and for the restoration unit of the group
          wire         lon  = lron_r && ltk[TS + LLAT][2];
          // window extension: row pairs {lower, upper} leaving position 0,
          // window columns 2..13; row pair b+j is in lx[TS-9-j] at stage TS
          reg  [239:0] lx [0:LRE-1];
          integer li;
          always @(posedge clk) begin
            lx[0] <= {vwin[0][RW + 20 +: 120], vwin[0][20 +: 120]};
            for (li = 1; li < LRE; li = li + 1) lx[li] <= lx[li-1];
          end
          // stripe edges, registered at stage TS - 1: rows -4, -3 repeat row
          // -2 (band 0), rows H+2, H+3 repeat row H+1 (band H/2 - 1)
          wire [5:0] bls = tok[TS][AW +: 6];
          reg        ltop, lbot;
          always @(posedge clk) begin
            ltop <= (bls == 6'd0);
            lbot <= (bls + 6'd1 == hh);
          end
          wire [1199:0] lrw;                        // rows 2b-4+i, i = 0..9
          for (gr = 0; gr < 5; gr = gr + 1) begin : g_lrow
            localparam integer LI = TS - 7 - gr;    // row pair b + gr - 2
            if (gr == 0) begin : g_t
              assign lrw[0 +: 120]   = ltop ? lx[TS-8][119:0] : lx[LI][119:0];
              assign lrw[120 +: 120] = ltop ? lx[TS-8][119:0] : lx[LI][239:120];
            end else if (gr == 4) begin : g_b
              assign lrw[960 +: 120]  = lbot ? lx[TS-10][239:120] : lx[LI][119:0];
              assign lrw[1080 +: 120] = lbot ? lx[TS-10][239:120] : lx[LI][239:120];
            end else begin : g_m
              assign lrw[240*gr +: 120]       = lx[LI][119:0];
              assign lrw[240*gr + 120 +: 120] = lx[LI][239:120];
            end
          end
          // stage TS: tap-pair sums and centre sample of the NS samples
          wire [NS*16*11-1:0] lps_w;
          wire [NS*10-1:0]    lcen_w;
          for (gy = 0; gy < NS; gy = gy + 1) begin : g_lsum
            localparam integer RS = 4 + gy / 4, CS = 4 + gy % 4;
            assign lcen_w[gy*10 +: 10] = lrw[RS*120 + CS*10 +: 10];
            for (gz = 0; gz < 16; gz = gz + 1) begin : g_k
              wire [9:0] sf = lrw[(RS + LDR(gz))*120 + (CS + LDC(gz))*10 +: 10];
              wire [9:0] sb = lrw[(RS - LDR(gz))*120 + (CS - LDC(gz))*10 +: 10];
              assign lps_w[(gy*16 + gz)*11 +: 11] = {1'b0, sf} + {1'b0, sb};
            end
          end
          // products, adder tree, Round2 by 7 (10 bit) or 9 (8-bit samples
          // normalised to 10 bit) and the clip; a negative sum clips to 0, so
          // no signed rounding.  MSTG = 2 (FPGA): registered tap sums, DSP
          // products, three tree levels, round; MSTG = 1 (ASIC): products of
          // the tap sums, two tree levels with the rounding in the second
          reg  [NS*10-1:0] ylr_q;                   // stage TS + LLAT
          reg  [NS*16*11-1:0] lps_q;
          reg  [NS*10-1:0]    lcen_q;
          always @(posedge clk) begin
            lps_q  <= lps_w;
            lcen_q <= lcen_w;
          end
          wire [NS*16*11-1:0] lps_m  = (MSTG == 2) ? lps_q  : lps_w;
          wire [NS*10-1:0]    lcen_m = (MSTG == 2) ? lcen_q : lcen_w;
          for (gy = 0; gy < NS; gy = gy + 1) begin : g_lmac
            wire [17*21-1:0] prf;                   // 17 products, 21-bit signed
            for (gz = 0; gz < 16; gz = gz + 1) begin : g_m
              localparam integer OF = LOFF(gz), WD = LW(gz);
              wire signed [11+WD:0] p;
              gdf_mul #(.AWD(12), .BWD(WD), .STG(MSTG)) u_m (.clk(clk),
                .a({1'b0, lps_m[(gy*16 + gz)*11 +: 11]}), .b(lcq[OF +: WD]), .p(p));
              assign prf[gz*21 +: 21] = {{(9 - WD){p[11+WD]}}, p};
            end
            wire signed [20:0] pc;
            gdf_mul #(.AWD(11), .BWD(10), .STG(MSTG)) u_c (.clk(clk),
              .a({1'b0, lcen_m[gy*10 +: 10]}), .b(lcq[95 +: 10]), .p(pc));
            assign prf[16*21 +: 21] = pc;
            reg [9:0] cq [0:4];                     // centre sample for LR off
            integer lj;
            always @(posedge clk) begin
              cq[0] <= lcen_m[gy*10 +: 10];
              for (lj = 1; lj <= 4; lj = lj + 1) cq[lj] <= cq[lj-1];
            end
            // final sum plus the rounding constant: a sum below the constant
            // is negative or rounds to 0, so its sign alone selects the clip
            reg  signed [24:0] sacc;
            wire signed [24:0] rnd = bd10_r ? 25'sd64 : 25'sd256;
            wire [9:0] x0r = (MSTG == 2) ? cq[4] : cq[1];
            // 17 products per sample: FPGA pipeline, three registered levels
            // (pairs, triples, total); ASIC pipeline, one level of five
            // partial sums and a combinational total
            if (MSTG == 2) begin : g_t3
              reg signed [21:0] s1 [0:8];
              reg signed [23:0] s2 [0:2];
              integer lt;
              always @(posedge clk) begin
                for (lt = 0; lt < 8; lt = lt + 1)
                  s1[lt] <= $signed(prf[(2*lt)*21 +: 21]) + $signed(prf[(2*lt+1)*21 +: 21]);
                s1[8] <= $signed(prf[16*21 +: 21]);
                s2[0] <= s1[0] + s1[1] + s1[2];
                s2[1] <= s1[3] + s1[4] + s1[5];
                s2[2] <= s1[6] + s1[7] + s1[8];
                sacc  <= s2[0] + s2[1] + s2[2] + rnd;
              end
            end else begin : g_t2
              reg signed [22:0] t1 [0:4];
              integer lt;
              always @(posedge clk) begin
                for (lt = 0; lt < 4; lt = lt + 1)
                  t1[lt] <= $signed(prf[(4*lt)*21 +: 21]) + $signed(prf[(4*lt+1)*21 +: 21])
                          + $signed(prf[(4*lt+2)*21 +: 21]) + $signed(prf[(4*lt+3)*21 +: 21]);
                t1[4] <= $signed(prf[16*21 +: 21]);
              end
              always @(*) sacc = t1[0] + t1[1] + t1[2] + t1[3] + t1[4] + rnd;
            end
            // Round2Signed(., 7) of the 10-bit normalized sum; 8-bit video
            // drops two more bits (the samples were shifted left by two)
            wire [17:0] rq = bd10_r ? sacc[24:7] : {2'b00, sacc[24:9]};
            wire [9:0]  x0 = bd10_r ? x0r : {2'b00, x0r[9:2]};
            always @(posedge clk)
              ylr_q[gy*10 +: 10] <= !lon ? x0
                                  : sacc[24] ? 10'd0
                                  : (rq > (bd10_r ? 18'd1023 : 18'd255))
                                    ? (bd10_r ? 10'd1023 : 10'd255) : rq[9:0];
          end
          // alignment with the correction of the GDF back end
          if (LDL == 0) begin : g_la0
            assign ylr_a = ylr_q;
          end else begin : g_la
            reg [NS*10-1:0] ylr_d [0:LDL-1];
            integer la;
            always @(posedge clk) begin
              ylr_d[0] <= ylr_q;
              for (la = 1; la < LDL; la = la + 1) ylr_d[la] <= ylr_d[la-1];
            end
            assign ylr_a = ylr_d[LDL-1];
          end
        end else begin : g_nolr
          assign ylr_a = {NS*10{1'b0}};
        end
      end else begin : g_nopcw
        always @(posedge clk) out_pcw <= 8'd0;
        assign ylr_a = {NS*10{1'b0}};
      end
    end
  endgenerate

  // --------------------------------------------------------------------------
  // stage 5: neighbour differences for NS samples x 18 pairs
  //   d3 = s[R-dy][X-dx] - s[R][X], d4 = s[R+dy][X+dx] - s[R][X]
  // --------------------------------------------------------------------------
  localparam DW = NS * 36 * 11;                // 3168 bits for NS = 8
  wire [DW-1:0] diff_w;
  genvar gs, gk;
  generate
    for (gs = 0; gs < NS; gs = gs + 1) begin : g_diff
      localparam integer R = 6 + gs / GC;
      localparam integer X = 6 + gs % GC;
      wire [9:0] cen = dsrc_f[10*FW*R + 10*X +: 10];
      for (gk = 0; gk < 18; gk = gk + 1) begin : g_k
        localparam integer DY = FDY(gk);
        localparam integer DXX = FDX(gk);
        wire [9:0] fwd = dsrc_f[10*FW*(R - DY) + 10*(X - DXX) +: 10];
        wire [9:0] bwd = dsrc_f[10*FW*(R + DY) + 10*(X + DXX) +: 10];
        wire [10:0] e3 = {1'b0, fwd} - {1'b0, cen};
        wire [10:0] e4 = {1'b0, bwd} - {1'b0, cen};
        // IDXF: per-feature bit-depth shift (8-bit differences fit 9 bits)
        wire sh = IDXF && !bd10_r;
        assign diff_w[(gs*36 + 2*gk)*11 +: 11]     = sh ? {e3[8:0], 2'b00} : e3;
        assign diff_w[(gs*36 + 2*gk + 1)*11 +: 11] = sh ? {e4[8:0], 2'b00} : e4;
      end
    end
  endgenerate

  reg [DW-1:0] diff_q;                         // stage 6
  generate
    if (LA || VS) begin : g_diff_la            // formed at stage 5
      always @(posedge clk) diff_q <= diff_w;
    end else begin : g_diff_dl                 // formed at stage W, delayed
      reg [DW-1:0] dl [1:5];
      integer dk;
      always @(posedge clk) begin
        dl[1] <= diff_w;
        for (dk = 2; dk <= 5; dk = dk + 1) dl[dk] <= dl[dk-1];
        diff_q <= dl[5];
      end
    end
  endgenerate

  // stage 5: class and raw gradient features
  reg [1:0]  cls_q  [0:NBL-1];
  reg [10:0] graw_q [0:NBL-1][0:3];
  always @(posedge clk) begin
    for (bb = 0; bb < NBL; bb = bb + 1) begin
      cls_q[bb] <= {(box[bb][2] <= box[bb][3]), (box[bb][0] <= box[bb][1])};
      for (bd = 0; bd < 4; bd = bd + 1)
        graw_q[bb][bd] <= (IDXF && !bd10_r) ? box[bb][bd][12:2]   // (box<<2)>>4
                                            : box[bb][bd][14:4];
    end
  end

  // --------------------------------------------------------------------------
  // selection stage 6: per-block alpha / weights by class; stage 7: gradient
  // features min(graw, alpha)
  // --------------------------------------------------------------------------
  function [197:0] asel_f; input [1:0] c;
    begin
      case (c)
        2'd0: asel_f = abus0; 2'd1: asel_f = abus1;
        2'd2: asel_f = abus2; default: asel_f = abus3;
      endcase
    end
  endfunction
  function [WS*10-1:0] wsel_f; input [1:0] c;
    begin
      case (c)
        2'd0: wsel_f = wbus0; 2'd1: wsel_f = wbus1;
        2'd2: wsel_f = wbus2; default: wsel_f = wbus3;
      endcase
    end
  endfunction

  // the weights are static during a segment: only the 2-bit class travels
  // down the pipeline, and each DSP stage selects its own weight slots
  reg [197:0]     asel_q  [0:NBL-1];   // stage 6
  reg [1:0]       cls_d1  [0:NBL-1];   // stage 6
  reg [1:0]       cls_d2  [0:NBL-1];   // stage 7
  reg [WS*10-1:0] wsel_q2 [0:NBL-1];   // stage 7: gradient DSP inputs (gradient slots)
  reg [WS*10-1:0] wsel_q3 [0:NBL-1];   // stage 8: spatial DSP inputs (spatial slots)
  reg [10:0]      graw_d  [0:NBL-1][0:3];
  reg [8:0]       gf_q    [0:NBL-1][0:3];
  reg             odd_q   [0:NBL-1];
  always @(posedge clk) begin
    for (bb = 0; bb < NBL; bb = bb + 1) begin
      asel_q[bb]  <= asel_f(cls_q[bb]);
      cls_d1[bb]  <= cls_q[bb];
      cls_d2[bb]  <= cls_d1[bb];
      wsel_q2[bb] <= wsel_f(cls_d1[bb]);
      wsel_q3[bb] <= wsel_f(cls_d2[bb]);
      odd_q[bb]   <= cls_q[bb][0];
      for (bd = 0; bd < 4; bd = bd + 1) begin
        graw_d[bb][bd] <= graw_q[bb][bd];
        gf_q[bb][bd]   <= (graw_d[bb][bd] > {2'b00, asel_q[bb][(18+bd)*9 +: 9]})
                          ? asel_q[bb][(18+bd)*9 +: 9] : graw_d[bb][bd][8:0];
      end
    end
  end

  // --------------------------------------------------------------------------
  // gradient MACs, once per block (R2)
  //   proposed: 4 products (M sub-filter); MACF: 3 outputs x 4 products
  //   DSP stages 8-9, sums 10-11, then aligned to the per-sample tree
  // --------------------------------------------------------------------------
  // gradient products per 2x2 block: four features times the weights of the
  // M output (all three outputs in the baseline MACF = 1); the arrays are
  // flattened for the generate loops
  localparam NGO = MACF ? 3 : 1;
  wire [NBL*4*9-1:0]    gf_b;
  wire [NBL*WS*10-1:0]  wsel2_b;
  wire [NBL*WS*10-1:0]  wsel3_b;
  genvar gb, gq, go;
  generate
    for (gb = 0; gb < NBL; gb = gb + 1) begin : g_flat
      for (gq = 0; gq < 4; gq = gq + 1) begin : g_q
        assign gf_b[(gb*4 + gq)*9 +: 9] = gf_q[gb][gq];
      end
      assign wsel2_b[gb*WS*10 +: WS*10] = wsel_q2[gb];
      assign wsel3_b[gb*WS*10 +: WS*10] = wsel_q3[gb];
    end
  endgenerate

  wire [NBL*NGO*4*20-1:0] gp_b;
  generate
    for (gb = 0; gb < NBL; gb = gb + 1) begin : g_gm
      for (go = 0; go < NGO; go = go + 1) begin : g_o
        for (gq = 0; gq < 4; gq = gq + 1) begin : g_d
          localparam integer SLOT = MACF ? (go*22 + 18 + gq) : (30 + gq);
          gdf_mul #(.STG(MSTG)) u_gm (
            .clk(clk),
            .a({1'b0, gf_b[(gb*4 + gq)*9 +: 9]}),
            .b(wsel2_b[gb*WS*10 + SLOT*10 +: 10]),
            .p(gp_b[((gb*NGO + go)*4 + gq)*20 +: 20]));
        end
      end
    end
  endgenerate

  reg signed [20:0] gs1_q [0:NBL-1][0:NGO-1][0:1];   // stage 10
  reg signed [21:0] gsum_q[0:NBL-1][0:NGO-1];        // stage 11 (proposed joins M at L2)
  reg signed [21:0] gsum_d[0:NBL-1][0:NGO-1];        // stage 12 (MACF joins at L3)
  integer gi2;
  always @(posedge clk) begin
    for (bb = 0; bb < NBL; bb = bb + 1)
      for (gi2 = 0; gi2 < NGO; gi2 = gi2 + 1) begin
        gs1_q[bb][gi2][0] <= $signed(gp_b[((bb*NGO + gi2)*4 + 0)*20 +: 20])
                           + $signed(gp_b[((bb*NGO + gi2)*4 + 1)*20 +: 20]);
        gs1_q[bb][gi2][1] <= $signed(gp_b[((bb*NGO + gi2)*4 + 2)*20 +: 20])
                           + $signed(gp_b[((bb*NGO + gi2)*4 + 3)*20 +: 20]);
        gsum_q[bb][gi2]   <= gs1_q[bb][gi2][0] + gs1_q[bb][gi2][1];
        gsum_d[bb][gi2]   <= gsum_q[bb][gi2];
      end
  end

  // class parity delayed to the swap stage (needed during stage 14)
  reg odd_d [0:NBL-1][0:7];
  integer od;
  always @(posedge clk) begin
    for (bb = 0; bb < NBL; bb = bb + 1) begin
      odd_d[bb][0] <= odd_q[bb];
      for (od = 1; od < 8; od = od + 1) odd_d[bb][od] <= odd_d[bb][od-1];
    end
  end

  // FIP: class delayed to the swap/bias stage (clsp[k] at stage 8 + k)
  reg [1:0] clsp [0:NBL-1][0:7];
  always @(posedge clk) begin
    for (bb = 0; bb < NBL; bb = bb + 1) begin
      clsp[bb][0] <= cls_d2[bb];
      for (od = 1; od < 8; od = od + 1) clsp[bb][od] <= clsp[bb][od-1];
    end
  end

  // --------------------------------------------------------------------------
  // per-sample datapath
  // --------------------------------------------------------------------------
  wire [NS*22*3-1:0] acc_w;         // per sample 3 x 22-bit accumulators
  genvar gss, gv;
  generate
    for (gss = 0; gss < NS; gss = gss + 1) begin : g_samp
      // block of the sample: band (gss / 2GC), block column ((gss % GC) / 2)
      localparam integer BLK = (gss / (2*GC)) * (GC/2) + (gss % GC) / 2;
      localparam integer WB  = BLK * WS * 10;     // weight base in wsel3_b
      // ---- stage 7: clip both differences with the class alpha
      //      clip(d, -a, a) by two parallel sign tests: a-d < 0, d+a < 0
      reg [36*11-1:0] clip_q;
      integer fk;
      reg signed [10:0] d3, d4, al;
      reg signed [11:0] hi3, lo3, hi4, lo4;
      always @(posedge clk) begin
        for (fk = 0; fk < 18; fk = fk + 1) begin
          d3  = diff_q[(gss*36 + 2*fk)*11 +: 11];
          d4  = diff_q[(gss*36 + 2*fk + 1)*11 +: 11];
          al  = {2'b00, asel_q[BLK][fk*9 +: 9]};
          hi3 = {al[10], al} - {d3[10], d3};
          lo3 = {d3[10], d3} + {al[10], al};
          hi4 = {al[10], al} - {d4[10], d4};
          lo4 = {d4[10], d4} + {al[10], al};
          clip_q[(2*fk)*11 +: 11]   <= hi3[11] ? al : (lo3[11] ? -al : d3);
          clip_q[(2*fk+1)*11 +: 11] <= hi4[11] ? al : (lo4[11] ? -al : d4);
        end
      end
      // ---- stage 8: pair sum and saturation to [-512, 511]
      reg [18*10-1:0] feat_b;
      reg signed [10:0] ssum;
      always @(posedge clk) begin
        for (fk = 0; fk < 18; fk = fk + 1) begin
          ssum = $signed(clip_q[(2*fk)*11 +: 11]) + $signed(clip_q[(2*fk+1)*11 +: 11]);
          feat_b[fk*10 +: 10] <= (ssum > 11'sd511) ? 10'b0111111111 :
                                 ((ssum < -11'sd512) ? 10'b1000000000 : ssum[9:0]);
        end
      end
      reg signed [21:0] acc0, acc1, acc2;
      if (!MACF && FIP) begin : g_fip
        // ---- stages 9-11: 15 pre-added products (f_a + w_b)(f_b + w_a) for the
        //      V (6), H (6) and M (3) pairs, and 10 feature products f_a f_b
        //      shared by the three sub-filters; the weight terms w_a w_b are in
        //      the class-dependent biases.  22-bit wrap-around arithmetic.
        wire [6*22-1:0]  mv_b, mh_b;
        wire [3*22-1:0]  mm_b;
        wire [10*20-1:0] ff_b;
        reg  [10*20-1:0] ff_d;
        for (gv = 0; gv < 6; gv = gv + 1) begin : g_mvh
          localparam integer VA = FFA(VFF(gv)), VB = FFB(VFF(gv));
          localparam integer HA = FFA(HFF(gv)), HB = FFB(HFF(gv));
          reg signed [10:0] bqv, bqh;             // second pre-additions (fabric)
          always @(posedge clk) begin
            bqv <= $signed(feat_b[VB*10 +: 10]) + $signed(wsel3_b[WB + VSLOT(VA)*10 +: 10]);
            bqh <= $signed(feat_b[HB*10 +: 10]) + $signed(wsel3_b[WB + (12 + HSLOT(HA))*10 +: 10]);
          end
          gdf_mulpre #(.STG(MSTG)) u_mv (.clk(clk),
            .fa(feat_b[VA*10 +: 10]), .wb(wsel3_b[WB + VSLOT(VB)*10 +: 10]),
            .bq(bqv), .p(mv_b[gv*22 +: 22]));
          gdf_mulpre #(.STG(MSTG)) u_mh (.clk(clk),
            .fa(feat_b[HA*10 +: 10]), .wb(wsel3_b[WB + (12 + HSLOT(HB))*10 +: 10]),
            .bq(bqh), .p(mh_b[gv*22 +: 22]));
        end
        for (gv = 0; gv < 3; gv = gv + 1) begin : g_mm
          localparam integer MA = FFA(MFF(gv)), MB = FFB(MFF(gv));
          reg signed [10:0] bqm;
          always @(posedge clk)
            bqm <= $signed(feat_b[MB*10 +: 10]) + $signed(wsel3_b[WB + (24 + MSLOT(MA))*10 +: 10]);
          gdf_mulpre #(.STG(MSTG)) u_mm (.clk(clk),
            .fa(feat_b[MA*10 +: 10]), .wb(wsel3_b[WB + (24 + MSLOT(MB))*10 +: 10]),
            .bq(bqm), .p(mm_b[gv*22 +: 22]));
        end
        for (gv = 0; gv < 10; gv = gv + 1) begin : g_ff
          gdf_mul #(.STG(MSTG)) u_ff (.clk(clk), .a(feat_b[FFA(gv)*10 +: 10]),
                                     .b(feat_b[FFB(gv)*10 +: 10]), .p(ff_b[gv*20 +: 20]));
        end
        always @(posedge clk) ff_d <= ff_b;
        // ---- stages 12-15: pre-added minus shared products, adder trees;
        //      M joins the block gradient sum at L2
        reg signed [21:0] v1 [0:5], h1 [0:5], m1 [0:2];
        reg signed [21:0] v2 [0:2], h2 [0:2], m2 [0:1];
        reg signed [21:0] v3 [0:1], h3 [0:1], m3;
        reg signed [21:0] v4, h4, m4;
        integer li;
        always @(posedge clk) begin
          for (li = 0; li < 6; li = li + 1) begin
            v1[li] <= $signed(mv_b[li*22 +: 22]) - $signed(ff_d[VFF(li)*20 +: 20]);
            h1[li] <= $signed(mh_b[li*22 +: 22]) - $signed(ff_d[HFF(li)*20 +: 20]);
          end
          for (li = 0; li < 3; li = li + 1)
            m1[li] <= $signed(mm_b[li*22 +: 22]) - $signed(ff_d[MFF(li)*20 +: 20]);
          for (li = 0; li < 3; li = li + 1) begin
            v2[li] <= v1[2*li] + v1[2*li+1];
            h2[li] <= h1[2*li] + h1[2*li+1];
          end
          m2[0] <= m1[0] + m1[1];
          m2[1] <= m1[2] + gsum_d[BLK][0];
          v3[0] <= v2[0] + v2[1]; v3[1] <= v2[2];
          h3[0] <= h2[0] + h2[1]; h3[1] <= h2[2];
          m3    <= m2[0] + m2[1];
          v4 <= v3[0] + v3[1];
          h4 <= h3[0] + h3[1];
          m4 <= m3;
        end
        // ---- stage ACCS: class-parity swap + class-dependent bias
        wire [1:0] cq = clsp[BLK][ACCS - 9];
        always @(posedge clk) begin
          acc0 <= (cq[0] ? h4 : v4) + $signed(cbias[cq][0]);
          acc1 <= (cq[0] ? v4 : h4) + $signed(cbias[cq][1]);
          acc2 <= m4 + $signed(cbias[cq][2]);
        end
      end else if (!MACF) begin : g_prop
        // ---- stages 9-10: products (V 12, H 12, M 6 spatial), one DSP each
        wire [12*20-1:0] pv_b, ph_b;
        wire [6*20-1:0]  pm_b;
        for (gv = 0; gv < 12; gv = gv + 1) begin : g_vh
          gdf_mul #(.STG(MSTG)) u_v (.clk(clk), .a(feat_b[VF(gv)*10 +: 10]),
                       .b(wsel3_b[WB + gv*10 +: 10]), .p(pv_b[gv*20 +: 20]));
          gdf_mul #(.STG(MSTG)) u_h (.clk(clk), .a(feat_b[HF(gv)*10 +: 10]),
                       .b(wsel3_b[WB + (12+gv)*10 +: 10]), .p(ph_b[gv*20 +: 20]));
        end
        for (gv = 0; gv < 6; gv = gv + 1) begin : g_m
          gdf_mul #(.STG(MSTG)) u_m (.clk(clk), .a(feat_b[MF(gv)*10 +: 10]),
                       .b(wsel3_b[WB + (24+gv)*10 +: 10]), .p(pm_b[gv*20 +: 20]));
        end
        // ---- stages 11-14: adder trees; M joins the block gradient sum at L2
        reg signed [21:0] v1 [0:5], h1 [0:5], m1 [0:2];
        reg signed [21:0] v2 [0:2], h2 [0:2], m2 [0:1];
        reg signed [21:0] v3 [0:1], h3 [0:1], m3;
        reg signed [21:0] v4, h4, m4;
        integer li;
        always @(posedge clk) begin
          for (li = 0; li < 6; li = li + 1) begin
            v1[li] <= $signed(pv_b[(2*li)*20 +: 20]) + $signed(pv_b[(2*li+1)*20 +: 20]);
            h1[li] <= $signed(ph_b[(2*li)*20 +: 20]) + $signed(ph_b[(2*li+1)*20 +: 20]);
          end
          for (li = 0; li < 3; li = li + 1)
            m1[li] <= $signed(pm_b[(2*li)*20 +: 20]) + $signed(pm_b[(2*li+1)*20 +: 20]);
          for (li = 0; li < 3; li = li + 1) begin
            v2[li] <= v1[2*li] + v1[2*li+1];
            h2[li] <= h1[2*li] + h1[2*li+1];
          end
          m2[0] <= m1[0] + m1[1];
          m2[1] <= m1[2] + gsum_q[BLK][0];
          v3[0] <= v2[0] + v2[1]; v3[1] <= v2[2];
          h3[0] <= h2[0] + h2[1]; h3[1] <= h2[2];
          m3    <= m2[0] + m2[1];
          v4 <= v3[0] + v3[1];
          h4 <= h3[0] + h3[1];
          m4 <= m3;
        end
        // ---- stage 15: class-parity swap (R1) + bias (R7)
        always @(posedge clk) begin
          acc0 <= (odd_d[BLK][5 + MSTG] ? h4 : v4) + $signed(bias0);
          acc1 <= (odd_d[BLK][5 + MSTG] ? v4 : h4) + $signed(bias1);
          acc2 <= m4 + $signed(bias2);
        end
      end else begin : g_full
        // ---- conventional: 3 outputs x 18 spatial products per sample
        wire [54*20-1:0] pf_b;
        for (gv = 0; gv < 54; gv = gv + 1) begin : g_pf
          gdf_mul #(.STG(MSTG)) u_f (.clk(clk), .a(feat_b[(gv % 18)*10 +: 10]),
                       .b(wsel3_b[WB + ((gv / 18)*22 + gv % 18)*10 +: 10]),
                       .p(pf_b[gv*20 +: 20]));
        end
        // adder tree of the 18 spatial products of each output, five
        // registered levels; the gradient sum of the block joins at level 3
        // and the bias after the last level
        reg signed [21:0] t1 [0:2][0:8];
        reg signed [21:0] t2 [0:2][0:4];
        reg signed [21:0] t3 [0:2][0:2];
        reg signed [21:0] t4 [0:2][0:1];
        reg signed [21:0] t5 [0:2];
        integer fo, fi;
        always @(posedge clk) begin
          for (fo = 0; fo < 3; fo = fo + 1) begin
            for (fi = 0; fi < 9; fi = fi + 1)
              t1[fo][fi] <= $signed(pf_b[(fo*18 + 2*fi)*20 +: 20])
                          + $signed(pf_b[(fo*18 + 2*fi + 1)*20 +: 20]);
            for (fi = 0; fi < 4; fi = fi + 1) t2[fo][fi] <= t1[fo][2*fi] + t1[fo][2*fi+1];
            t2[fo][4] <= t1[fo][8];
            t3[fo][0] <= t2[fo][0] + t2[fo][1];
            t3[fo][1] <= t2[fo][2] + t2[fo][3];
            t3[fo][2] <= t2[fo][4] + gsum_d[BLK][fo];
            t4[fo][0] <= t3[fo][0] + t3[fo][1];
            t4[fo][1] <= t3[fo][2];
            t5[fo]    <= t4[fo][0] + t4[fo][1];
          end
          acc0 <= t5[0] + $signed(bias0);
          acc1 <= t5[1] + $signed(bias1);
          acc2 <= t5[2] + $signed(bias2);
        end
      end
      assign acc_w[(gss*3 + 0)*22 +: 22] = acc0;
      assign acc_w[(gss*3 + 1)*22 +: 22] = acc1;
      assign acc_w[(gss*3 + 2)*22 +: 22] = acc2;
    end
  endgenerate

  // --------------------------------------------------------------------------
  // index quantisation: idx = clip(Round2Signed(acc * scale, 15), -L, L-1) + L
  //   Round2Signed(x, n) = (x + 2^(n-1) - [x < 0]) >>> n, and the offset L is
  //   folded into the rounding constant: idx = clip((x + K + [x >= 0]) >>> n)
  //   proposed (R5): intra n = 12 on acc, inter n = 15 on 5*acc (shift-add);
  //                  address = {i0, i1, i2} (R6)
  //   IDXF: acc * scale with a multiplier, n = 15, address (i0*L + i1)*L + i2
  // --------------------------------------------------------------------------
  wire [NS*12-1:0] addr_w;
  genvar gqs;
  generate
    for (gqs = 0; gqs < NS; gqs = gqs + 1) begin : g_quant
      reg [3:0] qi [0:2];
      genvar gc;
      for (gc = 0; gc < 3; gc = gc + 1) begin : g_c
        wire signed [21:0] av = acc_w[(gqs*3 + gc)*22 +: 22];
        if (!IDXF) begin : g_prop
          // stage 16: y = acc or 5*acc ; stage 17: t = y + K + [y >= 0]
          reg signed [24:0] qy;
          reg signed [24:0] qt;
          always @(posedge clk) begin
            qy <= intra_r ? {{3{av[21]}}, av}
                          : ({{1{av[21]}}, av, 2'b00} + {{3{av[21]}}, av});
            qt <= qy + (intra_r ? 25'sd34815 : 25'sd180223) + {24'd0, !qy[24]};
          end
          // stage 18 (combinational part): shift and clip to [0, 2L-1]
          wire signed [12:0] v = intra_r ? qt[24:12] : {{3{qt[24]}}, qt[24:15]};
          always @(*) qi[gc] = v[12] ? 4'd0
                             : (intra_r ? ((v > 13'sd15) ? 4'd15 : v[3:0])
                                        : ((v > 13'sd9)  ? 4'd9  : v[3:0]));
        end else begin : g_full
          // stage 16: acc (bias) ; 17-18: product with the scale (DSP)
          wire signed [26:0] qp;
          gdf_mul #(.AWD(22), .BWD(5), .STG(MSTG)) u_qs (.clk(clk), .a(av),
            .b(intra_r ? 5'sd8 : 5'sd5), .p(qp));
          // stage 19: t = y + K + [y >= 0], n = 15
          reg signed [26:0] qt;
          always @(posedge clk)
            qt <= qp + (intra_r ? 27'sd278527 : 27'sd180223) + {26'd0, !qp[26]};
          // stage 20: index
          wire signed [11:0] v = qt[26:15];
          reg [3:0] qr;
          always @(posedge clk)
            qr <= v[11] ? 4'd0 : (intra_r ? ((v > 12'sd15) ? 4'd15 : v[3:0])
                                          : ((v > 12'sd9)  ? 4'd9  : v[3:0]));
          always @(*) qi[gc] = qr;
        end
      end
      if (!IDXF) begin : g_addr
        reg [11:0] addr_q;                          // stage 18
        always @(posedge clk) addr_q <= {qi[0], qi[1], qi[2]};
        assign addr_w[gqs*12 +: 12] = addr_q;
      end else begin : g_addr_full
        // stages 21-22: (i0*L + i1)*L + i2 with multipliers
        reg [7:0]  a1;
        reg [3:0]  i2_d;
        reg [11:0] addr_q;
        wire [4:0] lsz = intra_r ? 5'd16 : 5'd10;
        always @(posedge clk) begin
          a1     <= qi[0] * lsz + qi[1];
          i2_d   <= qi[2];
          addr_q <= a1 * lsz + i2_d;
        end
        assign addr_w[gqs*12 +: 12] = addr_q;
      end
    end
  endgenerate

  // --------------------------------------------------------------------------
  // expected-error LUT: NS/2 dual-read copies of 4096 x 7 bit (2-cycle read)
  // --------------------------------------------------------------------------
  wire          lut_we = cfg_we && !cfg_addr[12];
  wire [NS*7-1:0] err_w;
  genvar gl;
  generate
    if (GDFB) begin : g_luts
      for (gl = 0; gl < NS/2; gl = gl + 1) begin : g_lut
        gdf_ram_lut u_lut (.clk(clk), .we(lut_we), .wa(cfg_addr[11:0]),
                           .wd(cfg_wdata[6:0]), .ra0(addr_w[(2*gl)*12 +: 12]),
                           .ra1(addr_w[(2*gl+1)*12 +: 12]),
                           .q0(err_w[(2*gl)*7 +: 7]), .q1(err_w[(2*gl+1)*7 +: 7]));
      end
    end else begin : g_noluts                 // PC-Wiener-only baseline
      assign err_w = {NS*7{1'b0}};
    end
  endgenerate

  // --------------------------------------------------------------------------
  // compensation, two stages: corr = Round2Signed(e * s_pic, n), n = 12 - bd
  //   stage A: p = e * s_pic (shift-add, R8; IDXF: multiplier)
  //   stage B: (p + 2^(n-1) - [p < 0]) >>> n
  // --------------------------------------------------------------------------
  //   LR = 1 rounds in stage A as well, so that stage B only adds the
  //   correction to the LR output: y = clip(LR + corr) (corr = 0 if GDF is off
  //   in the frame or in the block of the group)
  reg signed [9:0] pp_q [0:NS-1];
  reg [NS*7-1:0] err_d;
  reg [NS*7-1:0] cv_q;                          // LR = 1: rounded correction
  integer cs;
  reg signed [6:0] ev;
  reg signed [9:0] pp, tq, ta;
  always @(posedge clk) begin
    err_d <= err_w;
    for (cs = 0; cs < NS; cs = cs + 1) begin
      // stage A: expected error times the picture scale (1..4)
      ev = err_w[cs*7 +: 7];
      if (IDXF) pp = ev * $signed({1'b0, spic_r + 3'd1});
      else case (spic_r)
        2'd0: pp = ev;
        2'd1: pp = ev <<< 1;
        2'd2: pp = (ev <<< 1) + ev;
        default: pp = ev <<< 2;
      endcase
      pp_q[cs] <= pp;
      // LR = 1: Round2Signed(p, n) here already, n = 2 (10 bit) or 4 (8 bit)
      ta = pp + (bd10_r ? 10'sd1 : 10'sd7) + {9'd0, !pp[9]};
      cv_q[cs*7 +: 7] <= bd10_r ? ta[8:2] : {{2{ta[9]}}, ta[8:4]};
    end
  end

  reg signed [6:0]  cv;
  reg signed [11:0] yv;
  always @(posedge clk) begin
    // stage B: output registers; error and correction are zero where GDF is
    // off in the block of the group, the restored sample is the LR output
    // plus the correction, clipped to the bit depth
    out_err <= gtk[NTOK-2] ? err_d : {NS*7{1'b0}};
    for (cs = 0; cs < NS; cs = cs + 1) begin
      tq = pp_q[cs] + (bd10_r ? 10'sd1 : 10'sd7) + {9'd0, !pp_q[cs][9]};
      cv = LR ? cv_q[cs*7 +: 7] : (bd10_r ? tq[8:2] : {{2{tq[9]}}, tq[8:4]});
      out_corr[cs*7 +: 7] <= gtk[NTOK-2] ? cv : 7'sd0;
      yv = $signed({2'b00, ylr_a[cs*10 +: 10]}) + (gon ? {{5{cv[6]}}, cv} : 12'sd0);
      out_y[cs*10 +: 10] <= !LR ? 10'd0
                          : yv[11] ? 10'd0
                          : (yv > (bd10_r ? 12'sd1023 : 12'sd255))
                            ? (bd10_r ? 10'd1023 : 10'd255) : yv[9:0];
    end
  end

endmodule
`default_nettype wire

// Chroma loop restoration of AV2 (cross-component non-separable Wiener
// filter, 4:2:0) beside the luma column scan of gdf_core (VS = 1, NB = 1,
// GC = 4).  Bit-exact with AVM 1.0.0 (analysis/lrc_golden.py):
//   y = clip(Round2Signed(128 x0 + sum_k c_k (u(+d_k) + u(-d_k) - 2 x0)
//                                + sum_j d_j (l(p_j) - l0), 7))
// over 6 symmetric chroma pairs (taps 0..5) and 12 taps on the down-sampled
// luma (taps 6..17); U and V have their own filters.
//
// Scan.  Luma pass c reads luma strip c (columns 4c-6..4c-3), row pair p =
// 0..H/2+1 (rows 2p-2, 2p-1) per cycle.  Each luma word gives row p-1 of the
// down-sampled luma (cfl_ds_filter_index 0: 2x2 average, 1: vertical pair
// average, 2: decimation) at chroma columns 2c-3, 2c-2, realigned by one
// column to chroma strip c = columns 2c-4, 2c-3 (even, so that a strip never
// straddles a 32-column processing unit); the column 2c-2 is carried to the
// next pass.  The chroma word of the same cycle holds row p-1 of strip c and,
// at p = 0 and p = H/2+1, also the outer saved rows -2 and H/2+1, so that
// the H/2+4 chroma rows take the H/2+2 cycles of the luma pass.  Luma rows
// beyond the saved rows repeat the outermost one, so the down-sampled rows -2
// and H/2+1 come from luma rows -2 and H+1.
//
// A column buffer of H/2+2 words holds strips c-2 and c-1 (U, V and the down-
// sampled luma D) and the carried column; the window W[0..5] (newest W[5])
// holds six rows of strips c-2..c and shifts every cycle.  Row r of strip c-1
// leaves the window stage five cycles after its row r+2 has been read: rows
// 0..H/2-3 at p = r+4 (stage 0 index) of pass c, rows H/2-2, H/2-1 at p = 0, 1
// of the next pass (or two cycles after the last pass).  The rows are
// R_i = W[i+1] (rows r-2+i), except R0 = the top extra row for r = 0 and R4 =
// the bottom extra row for r = H/2-1.
//
// Picture edges (0x1C02): the decoder extends the down-sampled luma by
// replication, so its rows above / below and columns left / right of the
// picture take the nearest row / column; chroma rows and columns are input as
// the decoder sets them up.
module gdf_lrc #(
  parameter AW   = 5,                  // log2 of the max chunks per row
  parameter MSTG = 1                   // 2: FPGA pipeline (DSP products, 3-level tree)
)(
  input  wire          clk,
  input  wire          rst,
  input  wire          cfg_we,
  input  wire [12:0]   cfg_addr,
  input  wire [15:0]   cfg_wdata,
  input  wire          bd10,           // 10-bit video (else 8-bit samples)
  // luma column scan of gdf_core
  input  wire          seg_start,      // segment start accepted this cycle
  input  wire [6:0]    seg_h,          // luma rows H (multiple of 4)
  input  wire [AW:0]   seg_nch,        // passes of the segment
  input  wire          lw,             // a luma word is read this cycle
  input  wire [5:0]    vp,             // its row pair p
  input  wire [AW:0]   vc,             // its pass c
  input  wire [79:0]   ldata,          // native luma: row 2p-2 [39:0], 2p-1 [79:40]
  // chroma word of the same cycle: main row p-1 [39:0], extra row [79:40]
  // (row -2 at p = 0, row H/2+1 at p = H/2+1), each {V1, V0, U1, U0}
  input  wire [79:0]   cdata,
  input  wire [5:0]    clr,            // strip c: {V on, V bank, U on, U bank}
  // row oc_row of strip oc_strip (chroma columns 2s-4, 2s-3), s >= 2
  output reg           oc_valid,
  output reg  [5:0]    oc_row,
  output reg  [AW:0]   oc_strip,
  output reg  [39:0]   oc_y,           // {V1, V0, U1, U0}
  output wire          cbusy
);
  genvar gf, gj, gk;
  integer i;

  // ------------------------------------------------------------------ config
  // 0x1C02: {right [6], left [5], bottom [4], top [3], ds_type [2:1], on [0]}
  // 0x1D00 + (plane << 7) + (bank << 5) + tap: tap 0..17 of plane 0 (U) /
  //         1 (V), bank 0..3 (signed; widths 7, 6, 5, 4 for taps 0-1, 2-3,
  //         4-9, 10-17: ranges [-24,39], [-14,17], [-16,15], [-8,7])
  reg        con, etop, ebot, eleft, eright;
  reg  [1:0] dst;
  always @(posedge clk) begin
    if (rst) begin
      con <= 1'b0; dst <= 2'd0;
      etop <= 1'b0; ebot <= 1'b0; eleft <= 1'b0; eright <= 1'b0;
    end else if (cfg_we && cfg_addr == 13'h1C02) begin
      con    <= cfg_wdata[0];
      dst    <= cfg_wdata[2:1];
      etop   <= cfg_wdata[3];
      ebot   <= cfg_wdata[4];
      eleft  <= cfg_wdata[5];
      eright <= cfg_wdata[6];
    end
  end
  // tap writes are registered once (index, data) before the decode of the
  // 144 registers; the taps are first read tens of cycles after a segment
  // starts, and segments start after the configuration writes
  reg [6:0] tap [0:143];               // (plane*4 + bank)*18 + k
  reg       tw_we;
  reg [7:0] tw_i;
  reg [6:0] tw_d;
  always @(posedge clk) begin
    tw_we <= cfg_we && cfg_addr[12:8] == 5'h1D && cfg_addr[4:0] < 5'd18;
    tw_i  <= {1'b0, cfg_addr[7:5], 4'd0} + {4'd0, cfg_addr[7:5], 1'b0} + {3'd0, cfg_addr[4:0]};
    tw_d  <= cfg_wdata[6:0];
    if (tw_we) tap[tw_i] <= tw_d;
  end

  // ------------------------------------------------------------------ control
  reg  [5:0]  hh, hh1, hh2;            // H/2: chroma rows of the stripe, H/2+1, H/2-2
  reg         hh_2, hh_3;              // H/2 = 2, 3
  reg  [AW:0] nch_m1, cr;              // last pass; pass of column W_c - 1
  always @(posedge clk)
    if (seg_start) begin
      hh     <= seg_h[6:1];
      hh1    <= seg_h[6:1] + 6'd1;
      hh2    <= seg_h[6:1] - 6'd2;
      hh_2   <= (seg_h[6:1] == 6'd2);
      hh_3   <= (seg_h[6:1] == 6'd3);
      nch_m1 <= seg_nch - 1'b1;
      cr     <= seg_nch - 2'd2;        // W_c = 2 NCH - 6: column W_c-1 = 2c-3
    end

  // stage 0: input registers; column buffer read of row p-1 (address p).
  // The edge flags of stage 1 are decoded here from the scan position.
  reg         v0;
  reg  [5:0]  p0;
  reg  [AW:0] c0;
  reg  [79:0] l0r, c0r;
  reg  [5:0]  lr0;
  reg         lft, rg0, rg1;
  always @(posedge clk) begin
    v0  <= lw && !rst;
    p0  <= vp;
    c0  <= vc;
    l0r <= ldata;
    c0r <= cdata;
    lr0 <= clr;
    lft <= eleft  && (vc <= 1);                      // strips left of column 0
    rg0 <= eright && (vc == cr);                     // column 2c-2 = W_c
    rg1 <= eright && (vc == nch_m1);                 // columns W_c, W_c+1
  end
  // word: {carry [129:120], strip c-1 [119:60], strip c-2 [59:0]}, a strip
  // {D1, D0, V1, V0, U1, U0} (column 0 = even column at the LSBs)
  wire [129:0] cq;
  reg  [5:0]   cwa;
  reg          cwe;
  reg  [129:0] cwd;
  gdf_ram_sdp #(.W(130), .D(34), .AW(6)) u_ccb (.clk(clk), .re(1'b1), .ra(vp),
    .rq(cq), .we(cwe), .wa(cwa), .wd(cwd));

  // stage 1: down-sampled luma, realignment and left / right edges
  function [9:0] DS; input [1:0] t; input [9:0] a, b, c, d;   // a b over c d
    reg [11:0] s;
    reg [10:0] v;
    begin
      s = {2'b00, a} + {2'b00, b} + {2'b00, c} + {2'b00, d};
      v = {1'b0, a} + {1'b0, c};
      DS = (t == 2'd1) ? v[10:1] : (t == 2'd2) ? a : s[11:2];
    end
  endfunction
  wire [9:0] lu0 = l0r[9:0],   lu1 = l0r[19:10], lu2 = l0r[29:20], lu3 = l0r[39:30];
  wire [9:0] ll0 = l0r[49:40], ll1 = l0r[59:50], ll2 = l0r[69:60], ll3 = l0r[79:70];
  wire [9:0] dm0 = DS(dst, lu0, lu1, ll0, ll1);        // row p-1, column 2c-3
  wire [9:0] dm1 = DS(dst, lu2, lu3, ll2, ll3);        //          column 2c-2
  wire [9:0] dt0 = DS(dst, lu0, lu1, lu0, lu1);        // row -2 (p = 0)
  wire [9:0] dt1 = DS(dst, lu2, lu3, lu2, lu3);
  wire [9:0] db0 = DS(dst, ll0, ll1, ll0, ll1);        // row H/2+1 (p = H/2+1)
  wire [9:0] db1 = DS(dst, ll2, ll3, ll2, ll3);
  // {new carry (column 2c-2), column 2c-3, column 2c-4}
  function [29:0] ALN; input l, r0, r1; input [9:0] carry, m0, m1;
    begin
      if (l)       ALN = {m1, m1, m1};                 // column 0 = 2c-2 at c = 1
      else if (r0) ALN = {m0, m0, carry};              // W_c-1 carried forward
      else if (r1) ALN = {carry, carry, carry};
      else         ALN = {m1, m0, carry};
    end
  endfunction
  reg  [9:0]  ct, cbt;                                 // carries of the extra rows
  wire [29:0] am = ALN(lft, rg0, rg1, cq[129:120], dm0, dm1);
  wire [29:0] at = ALN(lft, rg0, rg1, ct,  dt0, dt1);
  wire [29:0] ab = ALN(lft, rg0, rg1, cbt, db0, db1);
  wire [59:0] sm = {am[19:0], c0r[39:0]};              // strip c, row p-1
  wire [59:0] st = {at[19:0], c0r[79:40]};             // strip c, row -2
  wire [59:0] sb = {ab[19:0], c0r[79:40]};             // strip c, row H/2+1
  wire        ptop = v0 && (p0 == 6'd0);
  wire        pbot = v0 && (p0 == hh1);
  always @(posedge clk) begin
    cwe <= v0 && !rst;
    cwa <= p0;
    cwd <= {am[29:20], sm, cq[119:60]};                // carry, strips c, c-1
    if (ptop) ct  <= at[29:20];
    if (pbot) cbt <= ab[29:20];
  end

  // stage 2: window rows {strip c, c-1, c-2} (180 b), extra rows, side info.
  // The extra rows of strips c-2..c shift in when strip c's arrives (top at
  // p = 0, bottom at p = H/2+1): the top rows serve row 0 (p >= 4, or p = 0 of
  // the next pass when H/2 = 2), the bottom rows row H/2-1 (p = 1 of the next
  // pass).  The side info moves at p = 2, after the last row of strip c-2.
  reg  [179:0] win [0:5];
  reg  [59:0]  tc0, tm1, tm2;          // row -2 of strips c, c-1, c-2
  reg  [59:0]  bc0, bm1, bm2;          // row H/2+1 of strips c, c-1, c-2
  reg  [5:0]   lrp, lrc, lrm1;         // side info of strips c (pending), c, c-1
  always @(posedge clk) begin
    for (i = 0; i < 5; i = i + 1) win[i] <= win[i + 1];
    win[5] <= {sm, cq[119:0]};
    if (ptop) begin
      tc0 <= st;
      tm1 <= tc0;
      tm2 <= tm1;
      lrp <= lr0;
    end
    if (pbot) begin
      bc0 <= sb;
      bm1 <= bc0;
      bm2 <= bm1;
    end
    if (v0 && (p0 == 6'd2)) begin
      lrm1 <= lrc;
      lrc  <= lrp;
    end
  end
  wire [179:0] trow = {tc0, tm1, tm2};
  wire [179:0] brow = {bc0, bm1, bm2};

  // ------------------------------------------------------------------ tokens
  // Output row r of strip s in S1: rows 0..H/2-3 of strip c-1 at stage-0
  // p = r+4 of pass c >= 3, rows H/2-2, H/2-1 of strip c-2 at p = 0, 1 of pass
  // c >= 4, and those of the last strip in the two cycles after the last pass
  // (tail).  The token is decoded one cycle early, from the scan position of
  // the word entering stage 0, and registered with its row flags.  A segment
  // starts while busy is low (as the configuration writes).
  reg         ltail, ltq;
  reg  [AW:0] lastc;
  wire        lend    = v0 && (p0 == hh1) && (c0 == nch_m1);       // last word
  wire        ltail_n = lend || (ltail && !ltq);
  wire        ltq_n   = !lend && ltail;
  wire [AW:0] lastc_n = lend ? c0 : lastc;
  always @(posedge clk) begin
    ltail <= ltail_n && !rst;
    ltq   <= ltq_n && !rst;
    lastc <= lastc_n;
  end
  wire        nmid = lw && (vp >= 6'd4) && (vp <= hh1) && (vc >= 3);
  wire        nnxt = lw && (vp <= 6'd1) && (vc >= 4);
  wire        nlst = ltail_n && (lastc_n >= 3);
  wire [5:0]  nrow = nmid ? vp - 6'd4 : hh2 + (nnxt ? vp : {5'd0, ltq_n});
  wire [AW:0] nstr = nmid ? vc - 1'b1 : (nnxt ? vc - 2'd2 : lastc_n - 1'b1);
  // row flags from the source of the row, not by comparing nrow (H/2 >= 2):
  // r = 0, r = 1, r = H/2-1, r = H/2-2
  wire        vq0 = (vp == 6'd0), vq1 = (vp == 6'd1);
  wire        nf0 = nmid ? (vp == 6'd4) : nnxt ? (hh_2 && vq0) : (hh_2 && !ltq_n);
  wire        nf1 = nmid ? (vp == 6'd5) : nnxt ? ((hh_2 && vq1) || (hh_3 && vq0))
                                              : ((hh_2 && ltq_n) || (hh_3 && !ltq_n));
  wire        nl0 = !nmid && (nnxt ? vq1 : ltq_n);
  wire        nl1 = !nmid && (nnxt ? vq0 : !ltq_n);
  reg         s1v, rfst, rlst, et0, et1, eb0, eb1;
  reg  [5:0]  s1r;
  reg  [AW:0] s1s;
  always @(posedge clk) begin
    s1v  <= con && (nmid || nnxt || nlst) && !rst;
    s1r  <= nrow;
    s1s  <= nstr;
    rfst <= nf0;
    rlst <= nl0;
    et0  <= etop && nf0;                               // top edge, r = 0
    et1  <= etop && nf1;                               //           r = 1
    eb0  <= ebot && nl0;                               // bottom edge, r = H/2-1
    eb1  <= ebot && nl1;                               //              r = H/2-2
  end

  // ------------------------------------------------------------------ S1
  // rows r-2..r+2
  wire [179:0] R0 = rfst ? trow : win[1];
  wire [179:0] R1 = win[2];
  wire [179:0] R2 = win[3];
  wire [179:0] R3 = win[4];
  wire [179:0] R4 = rlst ? brow : win[5];
  // down-sampled luma rows with the top / bottom edges: rows < 0 take row 0,
  // rows > H/2-1 take row H/2-1
  wire [179:0] D0 = et0 ? R2 : et1 ? R1 : R0;
  wire [179:0] D1 = et0 ? R2 : R1;
  wire [179:0] D3 = eb0 ? R2 : R3;
  wire [179:0] D4 = eb0 ? R2 : eb1 ? R3 : R4;
  wire [179:0] D2 = R2;
  // sample of a row at window column x (0..5) of plane f (0 U, 1 V, 2 D)
  function [9:0] PX; input [179:0] w; input integer x; input integer f;
    PX = w[(x / 2) * 60 + f * 20 + (x % 2) * 10 +: 10];
  endfunction
  function signed [11:0] PR; input [9:0] a, b, x0;   // a + b - 2 x0
    PR = $signed({2'b00, a}) + $signed({2'b00, b}) - $signed({1'b0, x0, 1'b0});
  endfunction
  function signed [10:0] LD; input [9:0] a, l0;      // a - l0
    LD = $signed({1'b0, a}) - $signed({1'b0, l0});
  endfunction
  function signed [6:0] SXT; input [6:0] v; input integer w;
    SXT = (w == 7) ? v : (w == 6) ? {v[5], v[5:0]} : (w == 5) ? {{2{v[4]}}, v[4:0]}
                                                    : {{3{v[3]}}, v[3:0]};
  endfunction
  function integer TW; input integer k;
    TW = (k < 2) ? 7 : (k < 4) ? 6 : (k < 10) ? 5 : 4;
  endfunction

  reg              s2v;
  reg  [5:0]       s2r;
  reg  [AW:0]      s2s;
  reg  [9:0]       x0q [0:3];                         // sample n = f*2 + j
  reg signed [11:0] prq [0:3][0:5];
  reg signed [10:0] ldq [0:1][0:11];                  // per column j (shared by U, V)
  reg signed [6:0] cfq [0:1][0:17];                   // per plane
  generate
    for (gf = 0; gf < 2; gf = gf + 1) begin : g_pl
      wire       on = lrm1[gf*3 + 2];
      wire [1:0] bk = lrm1[gf*3 +: 2];
      for (gk = 0; gk < 18; gk = gk + 1) begin : g_cf
        always @(posedge clk)
          cfq[gf][gk] <= on ? SXT(tap[({gf[0], bk} * 18) + gk], TW(gk)) : 7'sd0;
      end
      for (gj = 0; gj < 2; gj = gj + 1) begin : g_col
        localparam integer X = 2 + gj;                 // output column in the window
        wire [9:0] x0 = PX(R2, X, gf);
        always @(posedge clk) begin
          x0q[gf*2 + gj]    <= x0;
          prq[gf*2 + gj][0] <= PR(PX(R3, X, gf),     PX(R1, X, gf),     x0);
          prq[gf*2 + gj][1] <= PR(PX(R2, X + 1, gf), PX(R2, X - 1, gf), x0);
          prq[gf*2 + gj][2] <= PR(PX(R3, X + 1, gf), PX(R1, X - 1, gf), x0);
          prq[gf*2 + gj][3] <= PR(PX(R1, X + 1, gf), PX(R3, X - 1, gf), x0);
          prq[gf*2 + gj][4] <= PR(PX(R4, X, gf),     PX(R0, X, gf),     x0);
          prq[gf*2 + gj][5] <= PR(PX(R2, X + 2, gf), PX(R2, X - 2, gf), x0);
        end
      end
    end
    for (gj = 0; gj < 2; gj = gj + 1) begin : g_ld
      localparam integer X = 2 + gj;
      wire [9:0] l0 = PX(D2, X, 2);
      always @(posedge clk) begin
        ldq[gj][0]  <= LD(PX(D3, X, 2),     l0);           // ( 1,  0)
        ldq[gj][1]  <= LD(PX(D1, X, 2),     l0);           // (-1,  0)
        ldq[gj][2]  <= LD(PX(D2, X + 1, 2), l0);           // ( 0,  1)
        ldq[gj][3]  <= LD(PX(D2, X - 1, 2), l0);           // ( 0, -1)
        ldq[gj][4]  <= LD(PX(D3, X + 1, 2), l0);           // ( 1,  1)
        ldq[gj][5]  <= LD(PX(D1, X - 1, 2), l0);           // (-1, -1)
        ldq[gj][6]  <= LD(PX(D1, X + 1, 2), l0);           // (-1,  1)
        ldq[gj][7]  <= LD(PX(D3, X - 1, 2), l0);           // ( 1, -1)
        ldq[gj][8]  <= LD(PX(D4, X, 2),     l0);           // ( 2,  0)
        ldq[gj][9]  <= LD(PX(D0, X, 2),     l0);           // (-2,  0)
        ldq[gj][10] <= LD(PX(D2, X + 2, 2), l0);           // ( 0,  2)
        ldq[gj][11] <= LD(PX(D2, X - 2, 2), l0);           // ( 0, -2)
      end
    end
  endgenerate
  always @(posedge clk) begin
    s2v <= s1v && !rst;
    s2r <= s1r;
    s2s <= s1s;
  end

  // ------------------------------------------------------------------ S2-S4
  // S2 products; S3 two partial sums of the accumulator acc + 64 = (128 x0 +
  // 64 + taps 0..8) + (taps 9..17); S4 their sum, Round2Signed(acc, 7) =
  // (acc + 64) >> 7 for acc >= 0, and clip.  |acc| < 2^20 (the bound of
  // 128 x0 and every product), so 22 bits hold each partial sum.
  // MSTG = 2 (FPGA): products with the DSP M and P registers and a three-
  // level tree (pairs, triples, the two partial sums): XL = 3 more stages.
  localparam XL = (MSTG == 2) ? 3 : 0;
  reg              s3v, s4v;
  reg  [5:0]       s3r, s4r;
  reg  [AW:0]      s3s, s4s;
  reg signed [18:0] pq [0:3][0:17];
  reg  [9:0]       x3 [0:3];
  reg signed [21:0] acca [0:3], accb [0:3];
  generate
    for (gf = 0; gf < 2; gf = gf + 1) begin : g_mul
      for (gj = 0; gj < 2; gj = gj + 1) begin : g_mc
        localparam integer N = gf * 2 + gj;
        if (MSTG == 2) begin : g_f
          reg signed [18:0] pqa [0:17];          // DSP product register
          for (gk = 0; gk < 6; gk = gk + 1) begin : g_p
            always @(posedge clk) pqa[gk] <= prq[N][gk] * cfq[gf][gk];
          end
          for (gk = 0; gk < 12; gk = gk + 1) begin : g_l
            always @(posedge clk) pqa[6 + gk] <= ldq[gj][gk] * cfq[gf][6 + gk];
          end
          reg  [9:0]       xd [0:2];              // x0 to the last tree level
          reg signed [19:0] s1 [0:8];
          reg signed [21:0] s2 [0:2];
          integer t;
          always @(posedge clk) begin
            for (t = 0; t < 18; t = t + 1) pq[N][t] <= pqa[t];
            x3[N] <= x0q[N];
            xd[0] <= x3[N];
            xd[1] <= xd[0];
            xd[2] <= xd[1];
            for (t = 0; t < 9; t = t + 1) s1[t] <= pq[N][2*t] + pq[N][2*t + 1];
            s2[0]   <= s1[0] + s1[1] + s1[2];
            s2[1]   <= s1[3] + s1[4] + s1[5];
            s2[2]   <= s1[6] + s1[7] + s1[8];
            acca[N] <= $signed({5'd0, xd[2], 7'd64}) + s2[0] + s2[1];
            accb[N] <= s2[2];
          end
        end else begin : g_a
          for (gk = 0; gk < 6; gk = gk + 1) begin : g_p
            always @(posedge clk) pq[N][gk] <= prq[N][gk] * cfq[gf][gk];
          end
          for (gk = 0; gk < 12; gk = gk + 1) begin : g_l
            always @(posedge clk) pq[N][6 + gk] <= ldq[gj][gk] * cfq[gf][6 + gk];
          end
          always @(posedge clk) x3[N] <= x0q[N];
          reg signed [21:0] psa, psb;
          integer t;
          always @(*) begin
            psa = $signed({5'd0, x3[N], 7'd64});        // 128 x0 + 64
            for (t = 0; t < 9; t = t + 1) psa = psa + pq[N][t];
            psb = 22'sd0;
            for (t = 9; t < 18; t = t + 1) psb = psb + pq[N][t];
          end
          always @(posedge clk) begin
            acca[N] <= psa;
            accb[N] <= psb;
          end
        end
      end
    end
  endgenerate
  // the token of a sample follows its data through the XL extra stages
  wire          s2dv;
  wire [5:0]    s2dr;
  wire [AW:0]   s2ds;
  wire          xbusy;
  generate
    // XL-stage delay line of the token (valid, row, strip); none for XL = 0
    if (XL > 0) begin : g_xd
      reg  [XL-1:0] dv;
      reg  [5:0]    dr [0:XL-1];
      reg  [AW:0]   ds [0:XL-1];
      integer k;
      always @(posedge clk) begin
        dv    <= {dv[XL-2:0], s2v && !rst};
        dr[0] <= s2r;
        ds[0] <= s2s;
        for (k = 1; k < XL; k = k + 1) begin
          dr[k] <= dr[k-1];
          ds[k] <= ds[k-1];
        end
      end
      assign s2dv  = dv[XL-1];
      assign s2dr  = dr[XL-1];
      assign s2ds  = ds[XL-1];
      assign xbusy = |dv;
    end else begin : g_xn
      assign s2dv  = s2v;
      assign s2dr  = s2r;
      assign s2ds  = s2s;
      assign xbusy = 1'b0;
    end
  endgenerate
  always @(posedge clk) begin
    // the token of stages S3 and S4 (partial sums; total, rounding, clip)
    s3v <= s2dv && !rst; s3r <= s2dr; s3s <= s2ds;
    s4v <= s3v && !rst; s4r <= s3r; s4s <= s3s;
  end
  // S4: y = clip(Round2Signed(acc, 7)) from s = acc + 64; acc < 0 gives 0
  // (s < 0, or 0 <= s < 64 and s >> 7 = 0)
  function [9:0] RCL; input signed [21:0] a, b; input b10;
    reg signed [21:0] s;
    reg [14:0] q;
    begin
      s = a + b;
      q = s[21:7];
      if (s < 0)                               RCL = 10'd0;
      else if (q > (b10 ? 15'd1023 : 15'd255)) RCL = b10 ? 10'd1023 : 10'd255;
      else                                     RCL = q[9:0];
    end
  endfunction
  always @(posedge clk) begin
    oc_valid <= s4v && !rst;
    oc_row   <= s4r;
    oc_strip <= s4s;
    oc_y     <= {RCL(acca[3], accb[3], bd10), RCL(acca[2], accb[2], bd10),
                 RCL(acca[1], accb[1], bd10), RCL(acca[0], accb[0], bd10)};
  end
  assign cbusy = ltail || s1v || s2v || xbusy || s3v || s4v || oc_valid;
endmodule
