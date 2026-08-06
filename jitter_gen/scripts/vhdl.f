# ============================================================================
# vhdl.f -- VHDL Design & Testbench File List
#
# Used by:
#   run jitter_gen vhdl modelsim     (simulation: [rtl] + [tb:default])
#   run jitter_gen vhdl vivado       (synthesis: [rtl] + [top] only)
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
parallel_prng/rtl/xorshift128.vhd
parallel_prng/rtl/xorshift32.vhd
jitter_gen/rtl/jitter_gen.vhd

[top]
jitter_gen/rtl/jitter_gen_top.vhd

[tb:default]
top = jitter_gen_tb
jitter_gen/tb/jitter_gen_tb.vhd
