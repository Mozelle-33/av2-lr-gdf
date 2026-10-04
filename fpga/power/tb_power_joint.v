`timescale 1ns / 1ps
// Power simulation of the joint LR/GDF core (post-route functional netlist of
// an OOC run): replays the port trace of tb/tb_gdf.cpp (GDF_PORTDUMP, one line
// of input ports per rising edge) at 250 MHz, compares every valid output with
// the RTL trace (GDF_PORTDUMP_OUT) and stops ($stop) at the start and at the
// end of the measured window, so that the Tcl script records the switching
// activity (SAIF) of exactly the window of the ASIC power estimate.
// trace.vh (scripts/power_trace_fpga.sh, in the work directory) gives the
// trace length and window; with `define CHROMA (xvlog -d CHROMA) the chroma
// ports are driven and checked as well (GDF_PORTDUMP_C / _COUT traces).
`include "trace.vh"
module tb_power_joint;
  parameter N    = `TRACE_N;     // edges in ports.hex / outs.hex
  parameter WIN0 = `TRACE_WIN0;  // first edge of the window (ports.hex.win)
  parameter WLEN = `TRACE_WLEN;  // edges in the window
  reg clk = 1'b0;
  always #2.0 clk = ~clk;

  // port traces of the RTL simulation: inputs and expected outputs per edge
  reg [143:0] pin  [0:N-1];
  reg [223:0] pout [0:N-1];

  reg         rst, cfg_we, seg_start, in_valid, in_tskip, in_gdf;
  reg  [12:0] cfg_addr;
  reg  [15:0] cfg_wdata;
  reg  [6:0]  seg_h;
  reg  [10:0] seg_nch;
  reg  [2:0]  in_lr;
  reg  [79:0] in_data;
  wire        busy, in_ready, underrun, out_valid;
  wire [5:0]  out_band;
  wire [9:0]  out_group;
  wire [55:0] out_err, out_corr;
  wire [7:0]  out_pcw;
  wire [79:0] out_y;
`ifdef CHROMA
  reg  [87:0] cin  [0:N-1];
  reg  [63:0] cout [0:N-1];
  reg  [79:0] in_c_data;
  reg  [5:0]  in_c_lr;
  wire        out_c_valid;
  wire [5:0]  out_c_row;
  wire [10:0] out_c_strip;
  wire [39:0] out_c_y;
`endif

  gdf_core dut (
    .clk(clk), .rst(rst), .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata),
    .seg_start(seg_start), .seg_h(seg_h), .seg_nch(seg_nch), .busy(busy),
    .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data),
    .in_tskip(in_tskip), .in_lr(in_lr), .in_gdf(in_gdf), .underrun(underrun),
`ifdef CHROMA
    .in_c_data(in_c_data), .in_c_lr(in_c_lr), .out_c_valid(out_c_valid),
    .out_c_row(out_c_row), .out_c_strip(out_c_strip), .out_c_y(out_c_y),
`endif
    .out_valid(out_valid), .out_band(out_band), .out_group(out_group),
    .out_err(out_err), .out_corr(out_corr), .out_pcw(out_pcw), .out_y(out_y));

  // layout of tb_gdf.cpp: out_y, out_pcw, out_corr, out_err, out_group (16),
  // out_band, out_valid
  wire [223:0] got = {1'b0, out_valid, out_band, 6'd0, out_group,
                      out_err, out_corr, out_pcw, out_y};
`ifdef CHROMA
  // out_c_y, out_c_strip (16), out_c_row, out_c_valid
  wire [63:0] cgot = {1'b0, out_c_valid, out_c_row, 5'd0, out_c_strip, out_c_y};
`endif

  // drive the inputs of one edge from a trace line (layout of tb/tb_gdf.cpp)
  task apply(input [143:0] v);
    begin
      in_data   = v[79:0];
      in_gdf    = v[80];
      in_lr     = v[83:81];
      in_tskip  = v[84];
      in_valid  = v[85];
      seg_nch   = v[96:86];
      seg_h     = v[108:102];
      seg_start = v[109];
      cfg_wdata = v[125:110];
      cfg_addr  = v[138:126];
      cfg_we    = v[139];
      rst       = v[140];
    end
  endtask

  integer e, bad, checked, cchecked;
  initial begin
    $readmemh("ports.hex", pin);
    $readmemh("outs.hex", pout);
`ifdef CHROMA
    $readmemh("cports.hex", cin);
    $readmemh("couts.hex", cout);
    in_c_data = 80'd0;
    in_c_lr   = 6'd0;
`endif
    apply(144'd0);
    rst = 1'b1;
    bad = 0;
    checked = 0;
    cchecked = 0;
    repeat (40) @(posedge clk);          // past the 100-ns global set/reset
    for (e = 0; e < N; e = e + 1) begin
      #0.5 apply(pin[e]);
`ifdef CHROMA
      in_c_data = cin[e][79:0];
      in_c_lr   = cin[e][85:80];
`endif
      if (e == WIN0) begin
        $display("MARKER window start, edge %0d", e);
        $stop;
      end
      if (e == WIN0 + WLEN) begin
        $display("MARKER window end, edge %0d", e);
        $stop;
      end
      #3.0;                              // outputs of the previous edge
      if (pout[e][222]) begin
        checked = checked + 1;
        if (got !== pout[e]) begin
          bad = bad + 1;
          if (bad <= 5) $display("MISMATCH edge %0d: got %h want %h", e, got, pout[e]);
        end
      end else if (out_valid !== 1'b0) begin
        bad = bad + 1;
        if (bad <= 5) $display("MISMATCH edge %0d: out_valid %b", e, out_valid);
      end
`ifdef CHROMA
      if (cout[e][62]) begin
        cchecked = cchecked + 1;
        if (cgot !== cout[e]) begin
          bad = bad + 1;
          if (bad <= 5) $display("MISMATCH edge %0d: chroma got %h want %h", e, cgot, cout[e]);
        end
      end else if (out_c_valid !== 1'b0) begin
        bad = bad + 1;
        if (bad <= 5) $display("MISMATCH edge %0d: out_c_valid %b", e, out_c_valid);
      end
`endif
      @(posedge clk);
    end
    $display("DONE edges %0d, valid outputs checked %0d (chroma %0d), mismatches %0d",
             N, checked, cchecked, bad);
    $finish;
  end
endmodule
