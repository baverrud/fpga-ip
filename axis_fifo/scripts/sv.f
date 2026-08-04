# ============================================================================
# sv.f -- SystemVerilog Design & Simple Testbench File List
#
# Used by:
#   run axis_fifo modelsim sv        (simulation, all sections)
#   run axis_fifo vivado sv          (synthesis: [rtl] + [top] only)
#
# Section reference:
#   [rtl]   -- RTL sources always compiled
#   [top]   -- Top wrapper (synthesis only, not used in sim)
#   [tb]    -- Testbench (simulation only, skipped in synthesis)
#
# Notes:
#   - util_pkg (common/rtl/util_pkg.vhd) is VHDL but required by
#     axis_fifo_top.vhd and the UVVM testbenches for the log2ceil function.
#     Mixed-language simulators (ModelSim, Questa) handle this transparently.
#   - .sv files are compiled with vlog in sim, read_verilog -sv in Vivado.
# ============================================================================

# [rtl]
common/rtl/util_pkg.vhd
axis_fifo/rtl/axis_fifo.sv

# [top]
axis_fifo/rtl/axis_fifo_top.vhd

# [tb]
axis_fifo/tb/axis_fifo_tb_bfm_pkg.vhd
axis_fifo/tb/axis_fifo_tb.vhd