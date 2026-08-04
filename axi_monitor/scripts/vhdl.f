# ============================================================================
# vhdl.f -- axi_monitor VHDL RTL & Testbench File List
#
# Used by:
#   run axi_monitor vhdl modelsim     (simulation, all sections)
#   run axi_monitor vhdl vivado       (synthesis: [rtl] + [top] only)
#   run axi_monitor vhdl xsim         (XSim simulation)
#
# Section reference:
#   [rtl]   -- RTL sources always compiled
#   [top]   -- Top wrapper (synthesis only)
#   [tb]    -- Testbench (simulation only)
#
# Each line: <relative_path_from_sub_fpga_ip> [vhdl_std]
#   vhdl_std defaults to 2008 if omitted.
# ============================================================================

# Shared IP support
common/rtl/util_pkg.vhd
axis_fifo/rtl/axis_fifo.vhd
axilite_io/rtl/axilite_io.vhd
parallel_prng/rtl/xorshift128.vhd

# axi_monitor core
axi_monitor/rtl/axi_monitor_ar.vhd
axi_monitor/rtl/axi_monitor_r.vhd
axi_monitor/rtl/axi_monitor.vhd
axi_monitor/rtl/axi_ar_gen.vhd

# [top]  -- synthesis wrappers
axi_monitor/rtl/axi_monitor_top.vhd
axi_monitor/rtl/axi_monitor_reg.vhd

# [tb]  -- testbenches; use axi_ar_gen as the traffic source,
#         axi_mem_model as the responding slave, and axilite_bfm_pkg
#         for the register testbench.
common/rtl/axilite_bfm_pkg.vhd
parallel_prng/rtl/xorshift32.vhd
jitter_gen/rtl/jitter_gen.vhd
axis_latency_gen/rtl/axis_latency_gen.vhd
axi_mem_model/rtl/axi_mem_model_core.vhd
axi_mem_model/rtl/axi_mem_model.vhd
axi_monitor/tb/axi_monitor_tb.vhd
axi_monitor/tb/axi_monitor_reg_tb.vhd
