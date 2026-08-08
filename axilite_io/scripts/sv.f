# ============================================================================
# sv.f -- SystemVerilog Design & Simple Testbench File List
#
# Used by:
#   run axilite_io sv modelsim       (simulation: [rtl] + [tb:default])
#
# Section reference:
#   [rtl]        -- RTL sources always compiled
#   [tb:<name>]  -- Testbench (simulation only, skipped in synthesis)
#
# Notes:
#   - util_pkg (common/rtl/util_pkg.vhd) is VHDL but required for the
#     VHDL testbench wrappers. Mixed-language simulators (ModelSim, Questa)
#     handle this transparently.
#   - .sv files are compiled with vlog in sim, read_verilog -sv in Vivado.
#   - No [top] section: this manifest is simulation-only.
# ============================================================================
DEFAULT_STD: 2008
DEFAULT_LIB: work

[rtl]
axilite_io/rtl/axilite_io.sv

[top]
axilite_io/rtl/axilite_io_top.sv
top = axilite_io_top

[tb:default]
top = axilite_io_tb
axilite_io/tb/axilite_io_wrap.sv
common/rtl/util_pkg.vhd
axis_fifo/rtl/axis_fifo.vhd
axilite_io/tb/axilite_io_harness.vhd
axilite_io/tb/axilite_io_th.vhd
common/rtl/axilite_bfm_pkg.vhd
axilite_io/tb/axilite_io_tb.vhd
