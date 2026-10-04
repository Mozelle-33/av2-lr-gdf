// SRAM macros of the joint LR/GDF stage for the ASIC layout (asic/pnr/
// synth_mac.ys): the RAM modules of rtl/gdf_core.v mapped to the fakeram45
// macros of asic/macros/gen_gdf_macros.py (exact sizes; the ROMs of the RTL
// are synthesized into standard cells).  Same ports, parameters and cycle
// behavior as the RTL modules, except that the second read of an error table
// holds its output while the table is written (the stage never reads a table
// while it is written: the first read port does not read then either).

// simple dual-port RAM: one 1r1w macro
module gdf_ram_sdp #(
  parameter W    = 80,
  parameter D    = 32,
  parameter AW   = 5,
  parameter OREG = 0
)(
  input  wire          clk,
  input  wire          re,
  input  wire [AW-1:0] ra,
  output wire [W-1:0]  rq,
  input  wire          we,
  input  wire [AW-1:0] wa,
  input  wire [W-1:0]  wd
);
  wire [W-1:0] q1;
  generate
    if (W == 240 && D == 34 && AW == 6) begin : m
      fakeram45_1r1w_34x240 u_m (.clk(clk), .re_in(re), .raddr_in(ra), .rd_out(q1),
                                 .we_in(we), .waddr_in(wa), .wd_in(wd));
    end else if (W == 130 && D == 34 && AW == 6) begin : m
      fakeram45_1r1w_34x130 u_m (.clk(clk), .re_in(re), .raddr_in(ra), .rd_out(q1),
                                 .we_in(we), .waddr_in(wa), .wd_in(wd));
    end else if (W == 105 && D == 256 && AW == 8) begin : m
      fakeram45_1r1w_256x105 u_m (.clk(clk), .re_in(re), .raddr_in(ra), .rd_out(q1),
                                  .we_in(we), .waddr_in(wa), .wd_in(wd));
    end else if (W == 26 && D == 64 && AW == 6) begin : m
      fakeram45_1r1w_64x26 u_m (.clk(clk), .re_in(re), .raddr_in(ra), .rd_out(q1),
                                .we_in(we), .waddr_in(wa), .wd_in(wd));
    end else begin : m
      gdf_no_macro_for_this_size u_m ();   // no macro: fail elaboration
    end
  endgenerate
  reg [W-1:0] q2;
  always @(posedge clk) q2 <= q1;
  assign rq = OREG ? q2 : q1;
endmodule

// error table with two reads: two single-port macros written together
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
  wire [6:0] l0, l1;
  fakeram45_4096x7 u_m0 (.clk(clk), .ce_in(1'b1), .we_in(we), .addr_in(we ? wa : ra0),
                         .wd_in(wd), .rd_out(l0));
  fakeram45_4096x7 u_m1 (.clk(clk), .ce_in(1'b1), .we_in(we), .addr_in(we ? wa : ra1),
                         .wd_in(wd), .rd_out(l1));
  always @(posedge clk) begin q0 <= l0; q1 <= l1; end
endmodule
