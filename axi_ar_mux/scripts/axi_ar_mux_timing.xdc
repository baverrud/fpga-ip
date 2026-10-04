# axi_ar_mux standalone timing constraints (IP-level harness, not board level).
#
# 200 MHz internal clock. All input and output ports are false-pathed, so the
# result is register-to-register timing only. The combinational port paths
# req_valid/req_len -> req_ready and ar_ready -> AR state must be constrained
# by the integrating design.

create_clock -name aclk -period 5.000 [get_ports aclk]

set_false_path -from [all_inputs] -to [all_registers]
set_false_path -from [all_registers] -to [all_outputs]
set_false_path -from [all_inputs] -to [all_outputs]
