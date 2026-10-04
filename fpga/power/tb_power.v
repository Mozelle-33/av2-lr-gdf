`timescale 1ns / 1ps
// Power-simulation testbench for gdf_core (post-route functional netlist or
// RTL): replays ops.hex / in.hex (tools/make_power_stim.py) at 250 MHz,
// checks the CRC-32 signature of every segment and stops ($stop) at the
// marker op, so that the Tcl script can start SAIF logging for the measured
// window (the real-content segments of one table set).
module tb_power;
  parameter OPS_N = 8192;
  parameter IN_N  = 65536;
  reg clk = 1'b0;
  always #2.0 clk = ~clk;

  reg         rst = 1'b1;
  reg         cfg_we = 1'b0;
  reg  [12:0] cfg_addr = 13'd0;
  reg  [15:0] cfg_wdata = 16'd0;
  reg         seg_start = 1'b0;
  reg  [6:0]  seg_h = 7'd0;
  reg  [10:0] seg_nch = 11'd0;
  reg         in_valid = 1'b0;
  reg  [79:0] in_data = 80'd0;
  wire        busy, in_ready, underrun, out_valid;
  wire [5:0]  out_band;
  wire [9:0]  out_group;
  wire [55:0] out_err, out_corr;

  gdf_core dut (
    .clk(clk), .rst(rst), .cfg_we(cfg_we), .cfg_addr(cfg_addr), .cfg_wdata(cfg_wdata),
    .seg_start(seg_start), .seg_h(seg_h), .seg_nch(seg_nch), .busy(busy),
    .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data), .underrun(underrun),
    .out_valid(out_valid), .out_band(out_band), .out_group(out_group),
    .out_err(out_err), .out_corr(out_corr));

  reg [31:0] ops [0:OPS_N-1];
  reg [79:0] inw [0:IN_N-1];

  function [31:0] crc_upd;
    input [31:0]  c;
    input [111:0] d;
    integer i;
    reg [31:0] x;
    begin
      x = c;
      for (i = 111; i >= 0; i = i - 1)
        x = {x[30:0], 1'b0} ^ ((x[31] ^ d[i]) ? 32'h04C11DB7 : 32'h0);
      crc_upd = x;
    end
  endfunction

  // output signature (samples beyond the segment width are zero)
  reg  [31:0]  crc;
  reg  [9:0]   lastg;
  reg  [1:0]   lastv;
  reg  [111:0] md;
  integer s;
  always @(*) begin
    md = {out_corr, out_err};
    for (s = 0; s < 8; s = s + 1)
      if (out_group == lastg && (s % 4) > lastv) begin
        md[7*s +: 7]      = 7'd0;
        md[56 + 7*s +: 7] = 7'd0;
      end
  end
  always @(posedge clk) if (out_valid) crc <= crc_upd(crc, md);

  // input stream: in_data holds word ip; a word is consumed in every cycle
  // in which in_ready is high
  integer ip = 0;
  always @(posedge clk) if (in_valid && in_ready) ip <= ip + 1;
  always @(*) in_data = inw[ip];

  integer op = 0, nseg = 0, nbad = 0;
  reg [31:0] w, exp_crc;
  initial begin
    $readmemh("ops.hex", ops);
    $readmemh("in.hex", inw);
    // the post-route netlist holds its registers in the global set/reset
    // (glbl.GSR) for the first 100 ns: start well after that
    repeat (64) @(posedge clk);
    rst <= 1'b0;
    repeat (4) @(posedge clk);
    in_valid <= 1'b1;
    forever begin
      w = ops[op];
      op = op + 1;
      case (w[31:30])
        2'd0: begin
          $display("MARKER at %0t ns (op %0d)", $time, op);
          $stop;
        end
        2'd1: begin
          while (busy) @(posedge clk);
          cfg_we <= 1'b1; cfg_addr <= w[29:17]; cfg_wdata <= w[15:0];
          @(posedge clk);
          cfg_we <= 1'b0;
        end
        2'd2: begin
          exp_crc = ops[op];
          op = op + 1;
          while (busy) @(posedge clk);
          repeat (3) @(posedge clk);             // configuration writes settle
          seg_h   <= w[29:23];
          seg_nch <= w[22:12];
          lastg   <= w[22:12] - 11'd4;
          lastv   <= w[11:10];
          crc     <= 32'hFFFFFFFF;
          seg_start <= 1'b1;
          @(posedge clk);
          seg_start <= 1'b0;
          @(posedge clk);
          while (busy) @(posedge clk);
          repeat (2) @(posedge clk);
          nseg = nseg + 1;
          if (crc !== exp_crc) nbad = nbad + 1;
          $display("segment %0d H=%0d NCH=%0d crc %08x expected %08x %s at %0t ns",
                   nseg, w[29:23], w[22:12], crc, exp_crc,
                   (crc === exp_crc) ? "OK" : "MISMATCH", $time);
        end
        default: begin
          $display("DONE segments %0d mismatches %0d underrun %0d words %0d at %0t ns",
                   nseg, nbad, underrun, ip, $time);
          $finish;
        end
      endcase
    end
  end
endmodule
