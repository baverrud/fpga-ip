# ============================================================================
# vhdl.f -- VHDL Design & Testbench File List
#
# Used by:
#   run axis_latency_gen vhdl modelsim     (simulation: [rtl] + [tb:default])
#   run axis_latency_gen vhdl vivado       (synthesis: [rtl] + [top] only)
#
# Section reference:
#   [rtl]        -- RTL sources always compiled
#   [top]        -- Top wrapper (synthesis only, not used in sim)
#   [tb:<name>]  -- Testbench (simulation only, skipped in synthesis)
#
# Each line: <relative_path_from_sub_fpga_ip> [std=<vhdl_std>]
#   vhdl_std defaults to DEFAULT_STD (2008) if omitted.
# ============================================================================
DEFAULT_STD: 2008
DEFAULT_LIB: work

[rtl]
common/rtl/util_pkg.vhd
axis_fifo/rtl/axis_fifo.vhd
parallel_prng/rtl/xorshift32.vhd
parallel_prng/rtl/xorshift128.vhd
jitter_gen/rtl/jitter_gen.vhd
axis_latency_gen/rtl/axis_latency_gen.vhd

[top]
axis_latency_gen/rtl/axis_latency_gen_top.vhd

[tb:default]
top = axis_latency_gen_tb
common/rtl/axis_bfm_pkg.vhd
axis_latency_gen/tb/axis_latency_gen_tb.vhd
