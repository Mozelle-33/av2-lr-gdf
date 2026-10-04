# xsim batch script: run to the marker (table set loaded), then record the
# switching activity of the core over the real-content segments.
run all
open_saif power.saif
log_saif [get_objects -r /tb_power/dut/*]
run all
close_saif
quit
