## NetFirm-4E40-C self-test: only the 100 MHz LVDS oscillator is used.
## (Pins from the reverse-engineering notes; see ../common/netfirm_4e40c.xdc.)
set_property -dict {PACKAGE_PIN AB27 IOSTANDARD LVDS_25} [get_ports sys_clk_p]
set_property -dict {PACKAGE_PIN AC27 IOSTANDARD LVDS_25} [get_ports sys_clk_n]
create_clock -period 10.000 -name sys_clk [get_ports sys_clk_p]

## JTAG user register clock (TCK <= 15 MHz), asynchronous to the core clock
create_clock -period 66.666 -name jtag_tck [get_pins u_bs1/TCK]
set_clock_groups -asynchronous \
  -group [get_clocks -include_generated_clocks sys_clk] -group [get_clocks jtag_tck]

## Configuration / bitstream: unused pins float (U27 must not be pulled low)
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullnone [current_design]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 2.5 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
