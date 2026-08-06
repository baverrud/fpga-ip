# ============================================================================
# vhdl.f -- axi_monitor VHDL RTL & Testbench File List
#
# Used by:
#   run axi_monitor vhdl modelsim       (simulation; default tb: monitor)
#   run axi_monitor vhdl modelsim --tb reg   (register testbench)
#   run axi_monitor vhdl vivado         (synthesis: [rtl] + [top] only)
#   run axi_monitor vhdl xsim           (XSim simulation)
#
# Section reference:
#   [rtl]        -- RTL sources always compiled
#   [top]        -- Top wrapper (synthesis only, not used in sim)
#   [tb:<name>]  -- Testbench (simulation only, skipped in synthesis)
#
# Each line: <relative_path_from_sub_fpga_ip> [std=<vhdl_std>]
#   vhdl_std defaults to DEFAULT_STD (2008) if omitted.
#
# The [tb:*] sections use axi_ar_gen as the traffic source, axi_mem_model
# as the responding slave, and axilite_bfm_pkg for the register testbench.
# ============================================================================
DEFAULT_STD: 2008
DEFAULT_LIB: work
DEFAULT_TB: monitor

[rtl]
common/rtl/util_pkg.vhd
axis_fifo/rtl/axis_fifo.vhd
axilite_io/rtl/axilite_io.vhd
parallel_prng/rtl/xorshift128.vhd
axi_monitor/rtl/axi_monitor_ar.vhd
axi_monitor/rtl/axi_monitor_r.vhd
axi_monitor/rtl/axi_monitor.vhd
axi_monitor/rtl/axi_ar_gen.vhd

[top]
axi_monitor/rtl/axi_monitor_top.vhd
axi_monitor/rtl/axi_monitor_reg.vhd

[tb:monitor]
top = axi_monitor_tb
common/rtl/axilite_bfm_pkg.vhd
parallel_prng/rtl/xorshift32.vhd
jitter_gen/rtl/jitter_gen.vhd
axis_latency_gen/rtl/axis_latency_gen.vhd
axi_mem_model/rtl/axi_mem_model_core.vhd
axi_mem_model/rtl/axi_mem_model.vhd
axi_monitor/tb/axi_monitor_tb.vhd

[tb:reg]
top = axi_monitor_reg_tb
common/rtl/axilite_bfm_pkg.vhd
parallel_prng/rtl/xorshift32.vhd
jitter_gen/rtl/jitter_gen.vhd
axis_latency_gen/rtl/axis_latency_gen.vhd
axi_mem_model/rtl/axi_mem_model_core.vhd
axi_mem_model/rtl/axi_mem_model.vhd
axi_monitor/tb/axi_monitor_reg_tb.vhd
