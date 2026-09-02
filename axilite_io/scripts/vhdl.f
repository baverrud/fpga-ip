# ============================================================================
# vhdl.f -- VHDL Design & Simple Testbench File List
#
# Used by:
#   run axilite_io vhdl modelsim     (simulation: [rtl] + [tb:default])
#   run axilite_io vhdl xsim         (XSim simulation)
#
# Section reference:
#   [rtl]        -- RTL sources always compiled
#   [tb:<name>]  -- Testbench (simulation only, skipped in synthesis)
#
# Each line: <relative_path_from_sub_fpga_ip> [std=<vhdl_std>]
#   vhdl_std defaults to DEFAULT_STD (2008) if omitted.
#   No [top] section: this manifest is simulation-only.
# ============================================================================
DEFAULT_STD: 2008
DEFAULT_LIB: work

[rtl]
common/rtl/util_pkg.vhd
axilite_io/rtl/axilite_io.vhd

[top]
axilite_io/top/axilite_io_top.vhd

[tb:default]
top = axilite_io_tb
axilite_io/tb/axilite_io_wrap.vhd
axis_fifo/rtl/axis_fifo.vhd
axilite_io/tb/axilite_io_harness.vhd
axilite_io/tb/axilite_io_th.vhd
common/rtl/axilite_bfm_pkg.vhd
axilite_io/tb/axilite_io_tb.vhd
