// PC-Wiener class ROM of the stage as a macro (layout variant ROM_MACRO=1 of
// run_pnr_mac.sh): same ports and cycle behavior as gdf_rom_pcw of
// rtl/gdf_core.v (registered read of every cycle); the macro model holds the
// contents of rtl/pcw_class.hex.
module gdf_rom_pcw #(
  parameter FILE = "pcw_class.hex"
)(
  input  wire        clk,
  input  wire [11:0] a,
  output wire [7:0]  q
);
  fakeram45_rom_4096x8 u_m (.clk(clk), .ce_in(1'b1), .addr_in(a), .rd_out(q));
endmodule
