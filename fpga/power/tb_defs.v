// RTL configuration of the power testbench DUT (proposed FPGA core)
module tb_defs;
  defparam tb_power.dut.MAXCH = 1024;
  defparam tb_power.dut.AW    = 10;
  defparam tb_power.dut.FIP   = 1;
  defparam tb_power.dut.VS    = 1;
endmodule
