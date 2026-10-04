`default_nettype none
// ============================================================================
// Sequential ROM streamer.  The ROM is split into banks of 4096 words, each
// initialised from rom_<TAG>_<bb>.hex (tools/make_rom.py).  A read passes
//   address register -> BRAM (latch, output register) -> 4:1 mux -> NB/4:1
//   mux -> 16-entry first-word-fall-through FIFO,
// all registered, so the deep ROM does not limit the clock.  Reads are
// issued ahead under a credit window; the stream wraps after N words.
// ============================================================================
module gdf_rom_stream #(
  parameter W   = 80,
  parameter N   = 16,
  parameter AW  = 13,                 // >= 13
  parameter NB  = 1,                  // number of 4096-word banks
  parameter [15:0] TAG = "in"
)(
  input  wire         clk,
  input  wire         rst,
  input  wire         pop,
  output wire [W-1:0] dout,
  output wire         valid
);
  localparam BW = AW - 12;            // bank index width
  localparam NG = (NB + 3) / 4;       // first-level mux groups

  reg  [AW-1:0] a;
  (* max_fanout = 24 *) reg [11:0] off1;
  reg  [BW-1:0] bk1, bk2, bk3, bk4;
  reg           v1, v2, v3, v4, v5;
  reg  [4:0]    cnt;
  wire [4:0]    inflight = {4'd0, v1} + {4'd0, v2} + {4'd0, v3} + {4'd0, v4} + {4'd0, v5};
  wire          issue = (cnt + inflight) < 5'd14;
  wire          do_pop = pop && (cnt != 5'd0);

  always @(posedge clk) begin
    if (rst) begin
      a <= {AW{1'b0}};
      v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0; v4 <= 1'b0; v5 <= 1'b0;
    end else begin
      if (issue) a <= (a == N - 1) ? {AW{1'b0}} : a + 1'b1;
      v1 <= issue; v2 <= v1; v3 <= v2; v4 <= v3; v5 <= v4;
    end
    off1 <= a[11:0];
    bk1  <= a[AW-1:12];
    bk2  <= bk1;
    bk3  <= bk2;
    bk4  <= bk3;
  end

  // banks: 2-cycle registered read
  wire [4*NG*W-1:0] r2;
  genvar b;
  generate
    for (b = 0; b < 4 * NG; b = b + 1) begin : g_bank
      if (b < NB) begin : g_real
        localparam [7:0] D1 = 8'd48 + b / 10;
        localparam [7:0] D0 = 8'd48 + b % 10;
        localparam [103:0] FN = {"rom_", TAG, "_", D1, D0, ".hex"};
        (* rom_style = "block" *) reg [W-1:0] mem [0:4095];
        initial $readmemh(FN, mem);
        (* shreg_extract = "no" *) reg [W-1:0] q1, q2;
        always @(posedge clk) begin
          q1 <= mem[off1];
          q2 <= q1;
        end
        assign r2[b*W +: W] = q2;
      end else begin : g_pad
        assign r2[b*W +: W] = {W{1'b0}};
      end
    end
  endgenerate

  // two registered mux levels
  (* shreg_extract = "no" *) reg [W-1:0] m1 [0:NG-1];
  (* shreg_extract = "no" *) reg [W-1:0] m2;
  integer g;
  always @(posedge clk) begin
    for (g = 0; g < NG; g = g + 1)
      m1[g] <= r2[(4*g + bk3[1:0])*W +: W];
    m2 <= m1[bk4 >> 2];
  end

  // FWFT FIFO (distributed RAM)
  reg [W-1:0] fm [0:15];
  reg [3:0]   wp, rp;
  always @(posedge clk) if (v5) fm[wp] <= m2;
  always @(posedge clk) begin
    if (rst) begin
      wp <= 4'd0; rp <= 4'd0; cnt <= 5'd0;
    end else begin
      if (v5) wp <= wp + 4'd1;
      if (do_pop) rp <= rp + 4'd1;
      cnt <= cnt + {4'd0, v5} - {4'd0, do_pop};
    end
  end
  assign dout  = fm[rp];
  assign valid = (cnt != 5'd0);
endmodule

// ============================================================================
// On-chip self-test for gdf_core.  Replays a command stream (configuration
// writes, segment headers with the expected output CRC) and an input stream
// from block ROM at full rate, forever.  Every output group of a segment is
// folded into a CRC-32/MPEG-2 signature that is compared with the expected
// value when the segment has drained.  A snapshot of the statistics is taken
// at the end of every loop over the stream.
//
// ROM images: tools/make_rom.py (GDF), tools/make_rom_joint.py (LR = 1)
//   cmd (32 bit): 01|addr[29:17]|data[15:0]            config write
//                 10|H[29:23]|NCH[22:12]|LASTV[11:10]   segment header,
//                    |CLS[9]|GDF[8]                     (LR = 1: classes /
//                                                        GDF err, corr in the
//                                                        signature)
//                    followed by the expected CRC word
//                 00|n[29:16]|at[15:0]                  after a segment
//                    header: the next n config writes   header and CRC:
//                    are issued during the segment, one writes during the
//                    per cycle, once `at` input words   segment (LR banks
//                    have been accepted                 reloaded ahead of use)
//                 11                                    end of stream (loop)
//   in  (80 bit): input chunks in consumption order (LR = 1: 84 bit, the
//                 transform-skip side stream at bit 80 and the LR info
//                 {on, bank} of the group at [83:81])
// LR = 1 signs one 200-bit word per group: {y, class of odd bands, corr, err}.
// CH = 1 (chroma LR, tools/make_rom_joint.py --ch): 170-bit input words with
//   the chroma word of the luma word at [163:84] and the chroma side info
//   {V on, V bank, U on, U bank} of its strip at [169:164]; the segment
//   header carries CHK_U[7], CHK_V[6] (planes in the chroma signature) and
//   NOY[5] (luma outputs not signed: chroma-only segments) and is followed
//   by two CRC words, luma and chroma.  The chroma signature folds one 64-bit
//   word per chroma output, {7'b0, row, strip, V1, V0, U1, U0} with the
//   unchecked planes zero.
// snapshot[255:0] = {A55A, 8'h03 (CH: 8'h05, with in_gdf), flags, loops, seg_ok, seg_bad,
//                    groups, run_cycles, loop_cycles, bad_total}
//   flags = {5'b0, inject, cmd_error, underrun}; counters are per loop
//   except loops and bad_total.  run_cycles: seg_start .. core idle.
// inject: flips bit 7 of every input word of the first segment of a loop
// (checks that the comparison really detects errors).
// The configuration and segment-start signals reach the core through two
// register stages (placement slack between the ROMs and the core).
// ============================================================================
module gdf_selftest #(
  parameter CMD_N    = 16,
  parameter CMD_AW   = 13,
  parameter CMD_NB   = 1,
  parameter IN_N     = 16,
  parameter IN_AW    = 13,
  parameter IN_NB    = 1,
  parameter MAXCH    = 1024,
  parameter AW       = 10,
  parameter FIP      = 0,
  parameter VS       = 0,
  parameter LR       = 0,             // joint LR/GDF core (VS = 1, PCW = LR = 1)
  parameter CH       = 0,             // chroma LR (LR = 1)
  parameter PCWROM   = "pcw_class.hex",
  parameter LRSEL    = "pcw_sel.hex"
)(
  input  wire         clk,
  input  wire         rst_in,
  input  wire         inject,
  output reg  [255:0] snapshot
);
  (* max_fanout = 32 *) reg rst;
  always @(posedge clk) rst <= rst_in;
  localparam IWS  = CH ? 171 : (LR ? 85 : 80);   // input ROM word
  localparam CRCW = LR ? 200 : 112;     // signature word per group
  localparam CCW  = 64;                 // chroma signature word

  // ---------------------------------------------------------------- streams
  wire        cmd_valid, in_valid;
  wire [31:0] cmd_w;
  wire [IWS-1:0] in_w;
  wire        cmd_pop;
  wire        in_ready;

  gdf_rom_stream #(.W(32), .N(CMD_N), .AW(CMD_AW), .NB(CMD_NB), .TAG("cm")) u_cmd (
    .clk(clk), .rst(rst), .pop(cmd_pop), .dout(cmd_w), .valid(cmd_valid));
  gdf_rom_stream #(.W(IWS), .N(IN_N), .AW(IN_AW), .NB(IN_NB), .TAG("in")) u_in (
    .clk(clk), .rst(rst), .pop(in_ready), .dout(in_w), .valid(in_valid));
  wire [170:0] in_x  = {{(171 - IWS){1'b0}}, in_w};
  wire        in_tsk = LR ? in_x[80] : 1'b0;
  wire [2:0]  in_lri = LR ? in_x[83:81] : 3'd0;
  wire        in_gdf = LR ? !in_w[IWS-1] : 1'b1; // top bit of the word: GDF off

  // ---------------------------------------------------------------- core
  // configuration and segment-start signals of the sequencer, registered
  // twice on their way to the core (placement freedom at 250 MHz)
  reg          cfg_we0, cfg_we1, cfg_we2;
  reg  [12:0]  cfg_addr0, cfg_addr1, cfg_addr2;
  reg  [15:0]  cfg_wdata0, cfg_wdata1, cfg_wdata2;
  reg          seg_start0, seg_start1, seg_start2;
  reg  [6:0]   seg_h0, seg_h1, seg_h2;
  reg  [AW:0]  seg_nch0, seg_nch1, seg_nch2;
  reg          inj_seg;                  // corrupt the current segment
  wire         busy, out_valid, underrun;
  wire [5:0]   out_band;
  wire [AW-1:0] out_group;
  wire [55:0]  out_err, out_corr;
  wire [7:0]   out_pcw;
  wire [79:0]  out_y;
  wire         out_c_valid;
  wire [5:0]   out_c_row;
  wire [AW:0]  out_c_strip;
  wire [39:0]  out_c_y;

  always @(posedge clk) begin
    cfg_we1 <= cfg_we0;     cfg_we2 <= cfg_we1;
    cfg_addr1 <= cfg_addr0; cfg_addr2 <= cfg_addr1;
    cfg_wdata1 <= cfg_wdata0; cfg_wdata2 <= cfg_wdata1;
    seg_start1 <= seg_start0; seg_start2 <= seg_start1;
    seg_h1 <= seg_h0;       seg_h2 <= seg_h1;
    seg_nch1 <= seg_nch0;   seg_nch2 <= seg_nch1;
  end

  // device under test; inject flips one input bit of the marked segment
  gdf_core #(.MAXCH(MAXCH), .AW(AW), .FIP(FIP), .VS(VS), .PCW(LR), .LR(LR), .CH(CH),
             .PCWROM(PCWROM), .LRSEL(LRSEL)) u_core (
    .clk(clk), .rst(rst),
    .cfg_we(cfg_we2), .cfg_addr(cfg_addr2), .cfg_wdata(cfg_wdata2),
    .seg_start(seg_start2), .seg_h(seg_h2), .seg_nch(seg_nch2), .busy(busy),
    .in_valid(in_valid), .in_ready(in_ready),
    .in_data(in_w[79:0] ^ {72'd0, inj_seg, 7'd0}), .in_tskip(in_tsk), .in_lr(in_lri),
    .in_gdf(in_gdf), .underrun(underrun),
    .out_valid(out_valid), .out_band(out_band), .out_group(out_group),
    .out_err(out_err), .out_corr(out_corr), .out_pcw(out_pcw), .out_y(out_y),
    .in_c_data(in_x[163:84]), .in_c_lr(in_x[169:164]),
    .out_c_valid(out_c_valid), .out_c_row(out_c_row), .out_c_strip(out_c_strip),
    .out_c_y(out_c_y));

  // ---------------------------------------------------------------- signature
  // CRC-32/MPEG-2 (polynomial 0x04C11DB7, MSB first) over one signature
  // word per output group (crc_upd) and per chroma output (crc_updc)
  function [31:0] crc_upd;
    input [31:0]  c;
    input [199:0] d;
    integer i;
    reg [31:0] x;
    begin
      x = c;
      for (i = CRCW - 1; i >= 0; i = i - 1)
        x = {x[30:0], 1'b0} ^ ((x[31] ^ d[i]) ? 32'h04C11DB7 : 32'h0);
      crc_upd = x;
    end
  endfunction

  function [31:0] crc_updc;
    input [31:0]    c;
    input [CCW-1:0] d;
    integer i;
    reg [31:0] x;
    begin
      x = c;
      for (i = CCW - 1; i >= 0; i = i - 1)
        x = {x[30:0], 1'b0} ^ ((x[31] ^ d[i]) ? 32'h04C11DB7 : 32'h0);
      crc_updc = x;
    end
  endfunction

  reg  [AW-1:0] lastg;                   // index of the last group (NCH-4)
  reg  [1:0]    lastv;                   // valid columns in it, minus 1
  reg           chk_cls, chk_gdf;        // LR = 1: signature contents
  reg           chk_u, chk_v, noy;       // CH = 1: chroma planes, no luma
  reg           o_v;
  reg  [199:0]  o_d;
  reg  [31:0]   crc, exp_crc;
  reg           oc_v;                    // chroma signature
  reg  [CCW-1:0] oc_d;
  reg  [31:0]   crc_c, exp_crc_c;
  wire [39:0]   cym = {chk_v ? out_c_y[39:20] : 20'd0, chk_u ? out_c_y[19:0] : 20'd0};
  // the core outputs are registered once (with the last-group compare)
  // before the signature word is masked and registered (o_d)
  reg           a_v, a_odd, a_last;
  reg  [55:0]   a_err, a_corr;
  reg  [7:0]    a_pcw;
  reg  [79:0]   a_y;
  always @(posedge clk) begin
    a_v    <= out_valid && !(CH && noy);
    a_odd  <= out_band[0];
    a_last <= (out_group == lastg);
    a_err  <= out_err;
    a_corr <= out_corr;
    a_pcw  <= out_pcw;
    a_y    <= out_y;
  end
  // signature word of a group: y, class (odd bands), correction, error;
  // parts that the segment does not check and the samples beyond the last
  // column of the segment are zero, as in tools/make_rom_joint.py
  integer s;
  reg  [199:0]  md;
  always @(*) begin
    md = 200'd0;
    md[111:0] = {a_corr, a_err};
    if (LR) begin
      if (!chk_gdf) md[111:0] = 112'd0;
      md[119:112] = (chk_cls && a_odd) ? a_pcw : 8'd0;
      md[199:120] = a_y;
    end
    for (s = 0; s < 8; s = s + 1)
      if (a_last && (s % 4) > lastv) begin
        md[7*s +: 7]       = 7'd0;
        md[56 + 7*s +: 7]  = 7'd0;
        md[120 + 10*s +: 10] = 10'd0;
      end
  end

  // ---------------------------------------------------------------- sequencer
  localparam S_CMD = 3'd0, S_CRC = 3'd1, S_WAIT = 3'd2, S_ARM = 3'd3,
             S_RUN = 3'd4, S_DRAIN = 3'd5, S_CHECK = 3'd6, S_CRC2 = 3'd7;
  reg [2:0]  st;
  reg [1:0]  dcnt;
  reg [3:0]  qcnt;                       // config writes still in the pipe
  reg [15:0] in_cnt;                     // input words of the current segment
  reg [13:0] grp_left;                   // in-segment writes still to issue
  wire [1:0] ctype = cmd_w[31:30];
  // the trigger compare of an in-segment write group is registered (off the
  // path from the command FIFO): at_ok holds in_cnt >= `at` of the head of
  // the previous cycle, so it is used only if that head was already there
  // (no pop, valid); the group starts at most two cycles after its trigger
  reg        at_ok, cmd_fresh;
  always @(posedge clk) begin
    at_ok     <= (in_cnt >= cmd_w[15:0]);
    cmd_fresh <= cmd_valid && !cmd_pop;
  end
  // busy of the core, registered (the core becomes busy only after a
  // segment start of the sequencer, so a one-cycle-old value suffices)
  reg        busy_r;
  always @(posedge clk) busy_r <= busy;
  wire       run_pop = (st == S_RUN) &&
                       ((grp_left != 14'd0 && ctype == 2'b01) ||
                        (grp_left == 14'd0 && ctype == 2'b00 && at_ok && cmd_fresh));
  assign cmd_pop = cmd_valid && ((st == S_CRC) || (st == S_CRC2) ||
                   (st == S_CMD && (ctype != 2'b01 || !busy_r)) || run_pop);

  reg [31:0] loops, seg_ok, seg_bad, groups, run_cyc, loop_cyc, bad_total;
  reg        cmd_err, inj_r, first_seg;

  always @(posedge clk) begin
    o_v  <= a_v;
    o_d  <= md;
    oc_v <= CH && out_c_valid;
    oc_d <= {{(CCW - 47 - AW){1'b0}}, out_c_row, out_c_strip, cym};
    cfg_we0    <= 1'b0;
    seg_start0 <= 1'b0;
    if (rst) begin
      st <= S_CMD; inj_seg <= 1'b0; qcnt <= 4'd0; in_cnt <= 16'd0; grp_left <= 14'd0;
      loops <= 32'd0; seg_ok <= 32'd0; seg_bad <= 32'd0; groups <= 32'd0;
      run_cyc <= 32'd0; loop_cyc <= 32'd0; bad_total <= 32'd0;
      cmd_err <= 1'b0; inj_r <= 1'b0; first_seg <= 1'b1;
      crc <= 32'hFFFFFFFF;
      crc_c <= 32'hFFFFFFFF;
    end else begin
      loop_cyc <= loop_cyc + 32'd1;
      if (in_valid && in_ready) in_cnt <= in_cnt + 16'd1;
      if (o_v) begin
        crc    <= crc_upd(crc, o_d);
        groups <= groups + 32'd1;
      end
      if (oc_v) crc_c <= crc_updc(crc_c, oc_d);
      // S_CMD: configuration writes, segment header or end of the stream;
      // S_CRC/S_CRC2: expected signatures; S_WAIT: writes landed, core idle;
      // S_ARM/S_RUN: the segment runs (with its in-segment writes);
      // S_DRAIN/S_CHECK: last outputs registered, signatures compared
      case (st)
        S_CMD: if (cmd_valid) begin
          case (ctype)
            2'b01: if (!busy_r) begin
              cfg_we0    <= 1'b1;
              cfg_addr0  <= cmd_w[29:17];
              cfg_wdata0 <= cmd_w[15:0];
            end
            2'b10: begin
              seg_h0   <= cmd_w[29:23];
              seg_nch0 <= cmd_w[AW+12:12];
              lastg    <= cmd_w[AW+11:12] - 3'd4;
              lastv    <= cmd_w[11:10];
              chk_cls  <= cmd_w[9];
              chk_gdf  <= cmd_w[8];
              chk_u    <= cmd_w[7];
              chk_v    <= cmd_w[6];
              noy      <= cmd_w[5];
              st       <= S_CRC;
            end
            2'b11: begin
              snapshot <= {16'hA55A, (CH ? 8'h05 : 8'h03), 5'd0, inj_r, cmd_err, underrun,
                           loops + 32'd1, seg_ok, seg_bad, groups, run_cyc,
                           loop_cyc + 32'd1, bad_total};
              loops    <= loops + 32'd1;
              seg_ok   <= 32'd0; seg_bad <= 32'd0; groups <= 32'd0;
              run_cyc  <= 32'd0; loop_cyc <= 32'd0;
              inj_r     <= inject;
              first_seg <= 1'b1;
            end
            default: cmd_err <= 1'b1;
          endcase
        end
        S_CRC: if (cmd_valid) begin
          exp_crc <= cmd_w;
          qcnt    <= 4'd4;
          st      <= CH ? S_CRC2 : S_WAIT;
        end
        S_CRC2: if (cmd_valid) begin     // CH = 1: expected chroma signature
          exp_crc_c <= cmd_w;
          st        <= S_WAIT;
        end
        S_WAIT: begin                    // config writes landed, core idle
          if (qcnt != 4'd0) qcnt <= qcnt - 4'd1;
          else if (!busy_r) begin
            crc        <= 32'hFFFFFFFF;
            crc_c      <= 32'hFFFFFFFF;
            seg_start0 <= 1'b1;
            inj_seg    <= inj_r && first_seg;
            first_seg  <= 1'b0;
            in_cnt     <= 16'd0;
            grp_left   <= 14'd0;
            st         <= S_ARM;
          end
        end
        S_ARM: begin                     // wait until the core has started
          run_cyc <= run_cyc + 32'd1;
          if (busy_r) st <= S_RUN;
        end
        S_RUN: begin
          run_cyc <= run_cyc + 32'd1;
          if (run_pop && cmd_valid) begin
            if (ctype == 2'b00)
              grp_left <= cmd_w[29:16];
            else begin                   // config write during the segment
              cfg_we0    <= 1'b1;
              cfg_addr0  <= cmd_w[29:17];
              cfg_wdata0 <= cmd_w[15:0];
              grp_left   <= grp_left - 14'd1;
            end
          end
          if (!busy_r) begin               // drain: output register stage, o_d, CRC
            inj_seg <= 1'b0;
            dcnt    <= 2'd3;
            st      <= S_DRAIN;
          end
        end
        S_DRAIN: begin
          dcnt <= dcnt - 2'd1;
          if (dcnt == 2'd0) st <= S_CHECK;
        end
        S_CHECK: begin
          if (crc == exp_crc && (!CH || crc_c == exp_crc_c)) seg_ok <= seg_ok + 32'd1;
          else begin
            seg_bad   <= seg_bad + 32'd1;
            bad_total <= bad_total + 32'd1;
            // synthesis translate_off
            $display("selftest: segment %0d of the loop bad: luma crc %h (expected %h), chroma crc %h (%h)",
                     seg_ok + seg_bad, crc, exp_crc, crc_c, exp_crc_c);
            // synthesis translate_on
          end
          st <= S_CMD;
        end
        default: st <= S_CMD;
      endcase
    end
  end
endmodule
`default_nettype wire
