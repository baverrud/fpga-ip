# ============================================================================
# vhdl.f — VHDL Design & Simple Testbench File List
#
# Used by:
#   run axilite_io vhdl modelsim     (simulation, all sections)
#   run axilite_io vhdl vivado       (synthesis: [rtl] + [top] only)
#   run axilite_io vhdl xsim         (XSim simulation)
#
# Section reference:
#   [rtl]   — RTL sources always compiled
#   [tb]    — Testbench (simulation only, skipped in synthesis)
#   [top]   — Synthesis wrapper (none defined here)
#
# Each line: <relative_path_from_sub_fpga_ip> [vhdl_std]
#   vhdl_std defaults to 2008 if omitted; set explicitly with "93", "2008", etc.
# ============================================================================

# [rtl]
common/rtl/util_pkg.vhd
axilite_io/rtl/axilite_io.vhd

# [tb]
axilite_io/tb/axilite_io_wrap.vhd
axis_fifo/rtl/axis_fifo.vhd
axilite_io/tb/axilite_io_harness.vhd
axilite_io/tb/axilite_io_th.vhd
common/rtl/axilite_bfm_pkg.vhd
axilite_io/tb/axilite_io_tb.vhd
