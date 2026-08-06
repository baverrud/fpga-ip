# ============================================================================
# vhdl.f -- VHDL Design & Testbench File List
#
# Used by:
#   run parallel_prng vhdl modelsim     (simulation: [rtl] + [tb:default])
#   run parallel_prng vhdl vivado       (synthesis: [rtl] + [top] only)
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
parallel_prng/rtl/xorshift32.vhd
parallel_prng/rtl/xorshift128.vhd

[top]
parallel_prng/rtl/prng_top.vhd

[tb:default]
top = parallel_prng_tb
parallel_prng/tb/parallel_prng_tb.vhd
