# ============================================================================
# vhdl.f — VHDL Design & Testbench File List
#
# Used by:
#   run jitter_gen modelsim vhdl     (simulation, all sections)
#   run jitter_gen vivado vhdl       (synthesis: [rtl] + [top] only)
#
# Section reference:
#   [rtl]   — RTL sources always compiled
#   [top]   — Top wrapper (synthesis only, not used in sim)
#   [tb]    — Testbench (simulation only, skipped in synthesis)
#
# Each line: <relative_path_from_sub_fpga_ip> [vhdl_std]
#   vhdl_std defaults to 2008 if omitted; set explicitly with "93", "2008", etc.
# ============================================================================

# [rtl]
parallel_prng/rtl/xorshift128.vhd
parallel_prng/rtl/xorshift32.vhd
jitter_gen/rtl/jitter_gen.vhd

# [top]
jitter_gen/rtl/jitter_gen_top.vhd

# [tb]
jitter_gen/tb/jitter_gen_tb.vhd
