# ============================================================================
# vhdl.f -- VHDL RTL & Simple Testbench File List
#
# Used by:
#   run axi_read_tester vhdl modelsim     (simulation, all sections)
#   run axi_read_tester vhdl vivado       (synthesis: [rtl] + [top] only)
#   run axi_read_tester vhdl xsim         (XSim simulation)
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
parallel_prng/rtl/xorshift32.vhd
parallel_prng/rtl/xorshift128.vhd
jitter_gen/rtl/jitter_gen.vhd
axis_latency_gen/rtl/axis_latency_gen.vhd
axi_mem_model/rtl/axi_mem_model_core.vhd
axi_mem_model/rtl/axi_mem_model.vhd

# axi_read_tester core
axi_read_tester/rtl/axi_read_tester_ar_gen.vhd
axi_read_tester/rtl/axi_read_tester_r_mon.vhd
axi_read_tester/rtl/axi_read_tester.vhd

# [top]  -- synthesis wrapper
axi_read_tester/rtl/axi_read_tester_top.vhd

# [tb]  -- 10-phase corner-case testbench
axi_read_tester/tb/axi_read_tester_tb.vhd
