# ============================================================================
# sv-uvvm.f -- SystemVerilog + UVVM Verification File List
#
# Used by:
#   run axis_fifo sv-uvvm modelsim   (simulation; requires UVVM)
#   run axis_fifo sv-uvvm questa     (simulation; requires UVVM)
#
# Section reference:
#   [rtl]        -- RTL sources (util_pkg + axis_fifo.sv)
#   [tb:<name>]  -- UVVM test harness + sequencer
#
# Notes:
#   - util_pkg (common/rtl/util_pkg.vhd) provides log2ceil for all VHDL cores.
#     Mixed-language simulators (ModelSim, Questa) handle transparently.
#   - Uses SystemVerilog core (axis_fifo.sv) instead of VHDL core.
#   - Simulation-only manifest: no [top] section; use sv.f for synthesis.
# ============================================================================
DEFAULT_STD: 2008
DEFAULT_LIB: work

[rtl]
common/rtl/util_pkg.vhd
axis_fifo/rtl/axis_fifo.sv

[tb:default]
top = axis_fifo_uvvm_tb
requires = uvvm
time_res = fs
axis_fifo/tb/axis_fifo_uvvm_th.vhd
axis_fifo/tb/axis_fifo_uvvm_tb.vhd
