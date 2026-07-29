# ============================================================================
# vhdl.f — VHDL Design & Simple Testbench File List
#
# Used by:
#   run axis_fifo modelsim vhdl     (simulation, all sections)
#   run axis_fifo vivado vhdl       (synthesis: [rtl] + [top] only)
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
common/rtl/util_pkg.vhd
axis_fifo/rtl/axis_fifo.vhd

# [top]
axis_fifo/rtl/axis_fifo_top.vhd

# [tb]
axis_fifo/tb/axis_fifo_tb_bfm_pkg.vhd
axis_fifo/tb/axis_fifo_tb.vhd
