# ============================================================================
# vhdl.f -- VHDL Design & Testbench File List
#
# Used by:
#   run parallel_prng modelsim vhdl     (simulation, all sections)
#   run parallel_prng vivado vhdl       (synthesis: [rtl] + [top] only)
#
# Section reference:
#   [rtl]   -- RTL sources always compiled
#   [top]   -- Top wrapper (synthesis only, not used in sim)
#   [tb]    -- Testbench (simulation only, skipped in synthesis)
#
# Each line: <relative_path_from_sub_fpga_ip> [vhdl_std]
#   vhdl_std defaults to 2008 if omitted; set explicitly with "93", "2008", etc.
# ============================================================================

# [rtl]
parallel_prng/rtl/xorshift32.vhd
parallel_prng/rtl/xorshift128.vhd

# [top]
parallel_prng/rtl/prng_top.vhd

# [tb]
parallel_prng/tb/parallel_prng_tb.vhd
