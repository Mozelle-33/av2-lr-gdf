## NetFirm-4E40-C (XC7K325T-FFG900) board constraints.
## Pins from the reverse-engineering notes: https://www.cnblogs.com/ne5532/articles/19948478
## Banks 13/14/15 are powered at 2.5 V. DDR3 (1.5 V) pins are not mapped.
## Do NOT constrain or drive U27 (IO_L13P_T2_MRCC_14): pulling it low upsets the board.

## 100 MHz LVDS oscillator (bank 13)
set_property -dict {PACKAGE_PIN AB27 IOSTANDARD LVDS_25} [get_ports sys_clk_p]
set_property -dict {PACKAGE_PIN AC27 IOSTANDARD LVDS_25} [get_ports sys_clk_n]
create_clock -period 10.000 -name sys_clk [get_ports sys_clk_p]

## LEDs (bank 15, 2.5 V)
# Z2..Z5: active high
set_property -dict {PACKAGE_PIN N27 IOSTANDARD LVCMOS25} [get_ports {led_z2_z5[0]}]
set_property -dict {PACKAGE_PIN M27 IOSTANDARD LVCMOS25} [get_ports {led_z2_z5[1]}]
set_property -dict {PACKAGE_PIN N29 IOSTANDARD LVCMOS25} [get_ports {led_z2_z5[2]}]
set_property -dict {PACKAGE_PIN N30 IOSTANDARD LVCMOS25} [get_ports {led_z2_z5[3]}]
# Z6..Z9: active low
set_property -dict {PACKAGE_PIN L21 IOSTANDARD LVCMOS25} [get_ports {led_z6_z9_n[0]}]
set_property -dict {PACKAGE_PIN K24 IOSTANDARD LVCMOS25} [get_ports {led_z6_z9_n[1]}]
set_property -dict {PACKAGE_PIN K21 IOSTANDARD LVCMOS25} [get_ports {led_z6_z9_n[2]}]
set_property -dict {PACKAGE_PIN J21 IOSTANDARD LVCMOS25} [get_ports {led_z6_z9_n[3]}]
# corner LEDs: active high; [0] upper right, [1] lower right, [2] upper left, [3] lower left
set_property -dict {PACKAGE_PIN J28 IOSTANDARD LVCMOS25} [get_ports {led_corner[0]}]
set_property -dict {PACKAGE_PIN K30 IOSTANDARD LVCMOS25} [get_ports {led_corner[1]}]
set_property -dict {PACKAGE_PIN L30 IOSTANDARD LVCMOS25} [get_ports {led_corner[2]}]
set_property -dict {PACKAGE_PIN K26 IOSTANDARD LVCMOS25} [get_ports {led_corner[3]}]

## SFP transmitter enables (Q35..Q38 gates, active high) - keep low
set_property -dict {PACKAGE_PIN T28 IOSTANDARD LVCMOS25} [get_ports {sfp_tx_en[0]}]
set_property -dict {PACKAGE_PIN T26 IOSTANDARD LVCMOS25} [get_ports {sfp_tx_en[1]}]
set_property -dict {PACKAGE_PIN R30 IOSTANDARD LVCMOS25} [get_ports {sfp_tx_en[2]}]
set_property -dict {PACKAGE_PIN U30 IOSTANDARD LVCMOS25} [get_ports {sfp_tx_en[3]}]

set_false_path -to [get_ports -quiet {led_* sfp_tx_en[*]}]

## Configuration / bitstream
# Unused pins float, as in the original reverse-engineering design (the default
# weak pull-down could hold U27 low).
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullnone [current_design]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 2.5 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
