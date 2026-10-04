# xsim batch script for tb_power_joint: run to the window start, record the
# switching activity of the core over the window, then finish the replay
# (output check) after closing the SAIF file.
run all
open_saif power.saif
log_saif [get_objects -r /tb_power_joint/dut/*]
run all
close_saif
run all
quit
