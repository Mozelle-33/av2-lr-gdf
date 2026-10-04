`default_nettype none
// ============================================================================
// NetFirm-4E40-C (XC7K325T-FFG900) on-board self-test of the GDF core.
//
// Only the 100 MHz LVDS oscillator input (AB27/AC27) is used; no other pin
// is constrained or driven (unused pins float: BITSTREAM.CONFIG.UNUSEDPIN
// Pullnone).  Host access is JTAG only:
//   USER1 (IR 0x02), 264-bit read:  {6'b0, run, mmcm_locked, snapshot[255:0]}
//   USER2 (IR 0x03), 32-bit write:  {16'hC0DE, 14'b0, inject, soft_reset}
// (writes without the C0DE key are ignored, so a stray scan cannot disturb
// the test).  See gdf_selftest.v for the snapshot layout.
// ============================================================================
module selftest_top #(
  parameter real CLK_DIV = 4.0,     // MMCM CLKOUT0 divide, VCO = 1000 MHz
  parameter FIP = 0,                // fast-inner-product datapath
  parameter VS  = 0,                // column-major stripe scan
  parameter LR  = 0,                // joint LR/GDF core (VS = 1)
  parameter CH  = 0                 // chroma LR (LR = 1)
)(
  input  wire sys_clk_p,
  input  wire sys_clk_n
);
  `include "rom_params.vh"

  // ---------------------------------------------------------------- clocking
  wire clk_ibuf, clkfb, clkfb_buf, clk_mmcm, clk, locked;
  IBUFDS #(.DIFF_TERM("FALSE"), .IOSTANDARD("LVDS_25")) u_ibufds (
    .I(sys_clk_p), .IB(sys_clk_n), .O(clk_ibuf));
  MMCME2_BASE #(
    .CLKIN1_PERIOD(10.0), .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT_F(10.0),
    .CLKOUT0_DIVIDE_F(CLK_DIV)
  ) u_mmcm (
    .CLKIN1(clk_ibuf), .CLKFBIN(clkfb_buf), .CLKFBOUT(clkfb),
    .CLKOUT0(clk_mmcm), .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(),
    .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(),
    .CLKOUT5(), .CLKOUT6(), .CLKFBOUTB(), .LOCKED(locked),
    .PWRDWN(1'b0), .RST(1'b0));
  BUFG u_bufgfb (.I(clkfb), .O(clkfb_buf));
  BUFG u_bufg   (.I(clk_mmcm), .O(clk));

  // ---------------------------------------------------------------- JTAG
  wire tck_raw, tck, tdi;
  wire sel1, shift1, capture1, sel2, shift2, update2;
  wire tdo1, tdo2;
  BSCANE2 #(.JTAG_CHAIN(1)) u_bs1 (
    .CAPTURE(capture1), .DRCK(), .RESET(), .RUNTEST(), .SEL(sel1), .SHIFT(shift1),
    .TCK(tck_raw), .TDI(tdi), .TMS(), .UPDATE(), .TDO(tdo1));
  BSCANE2 #(.JTAG_CHAIN(2)) u_bs2 (
    .CAPTURE(), .DRCK(), .RESET(), .RUNTEST(), .SEL(sel2), .SHIFT(shift2),
    .TCK(), .TDI(), .TMS(), .UPDATE(update2), .TDO(tdo2));
  BUFG u_bufg_tck (.I(tck_raw), .O(tck));

  // USER2: control word (TCK domain)
  reg [31:0] sr2 = 32'd0, ctrl = 32'd0;
  always @(posedge tck) begin
    if (sel2 && shift2) sr2 <= {tdi, sr2[31:1]};
    if (sel2 && update2 && sr2[31:16] == 16'hC0DE) ctrl <= sr2;
  end
  assign tdo2 = sr2[0];

  // ---------------------------------------------------------------- reset
  (* ASYNC_REG = "TRUE" *) reg [2:0] lock_s = 3'd0, srst_s = 3'd0, inj_s = 3'd0;
  reg [20:0] por = 21'd0;
  reg        rst = 1'b1;
  always @(posedge clk) begin
    lock_s <= {lock_s[1:0], locked};
    srst_s <= {srst_s[1:0], ctrl[0]};
    inj_s  <= {inj_s[1:0], ctrl[1]};
    if (!lock_s[2] || srst_s[2]) begin
      por <= 21'd0;
      rst <= 1'b1;
    end else if (!por[20]) begin
      por <= por + 21'd1;
    end else begin
      rst <= 1'b0;
    end
  end

  // ---------------------------------------------------------------- self-test
  wire [255:0] snapshot;
  gdf_selftest #(
    .CMD_N(CMD_N), .CMD_AW(CMD_AW), .CMD_NB(CMD_NB),
    .IN_N(IN_N), .IN_AW(IN_AW), .IN_NB(IN_NB), .MAXCH(1024), .AW(10), .FIP(FIP), .VS(VS),
    .LR(LR), .CH(CH)
  ) u_st (
    .clk(clk), .rst_in(rst), .inject(inj_s[2]), .snapshot(snapshot));

  // USER1: status capture (TCK domain; the snapshot changes once per loop,
  // the host reads twice and compares)
  reg [263:0] sr1 = 264'd0;
  always @(posedge tck) begin
    if (sel1 && capture1)    sr1 <= {6'd0, !rst, locked, snapshot};
    else if (sel1 && shift1) sr1 <= {tdi, sr1[263:1]};
  end
  assign tdo1 = sr1[0];
endmodule
`default_nettype wire
