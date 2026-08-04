# ============================================================================
# sv.f -- SystemVerilog Design & Simple Testbench File List
#
# Used by:
#   run axilite_io modelsim sv        (simulation, all sections)
#   run axilite_io vivado sv          (synthesis: [rtl] + [top] only)
#
# Section reference:
#   [rtl]   -- RTL sources always compiled
#   [tb]    -- Testbench (simulation only, skipped in synthesis)
#   [top]   -- Synthesis wrapper (none defined here)
#
# Notes:
#   - util_pkg (common/rtl/util_pkg.vhd) is VHDL but required for the
#     VHDL testbench wrappers. Mixed-language simulators (ModelSim, Questa)
#     handle this transparently.
#   - .sv files are compiled with vlog in sim, read_verilog -sv in Vivado.
# ============================================================================

# [rtl]
axilite_io/rtl/axilite_io.sv

# [tb]
axilite_io/tb/axilite_io_wrap.sv
common/rtl/util_pkg.vhd
axis_fifo/rtl/axis_fifo.vhd
axilite_io/tb/axilite_io_harness.vhd
axilite_io/tb/axilite_io_th.vhd
common/rtl/axilite_bfm_pkg.vhd
axilite_io/tb/axilite_io_tb.vhd
