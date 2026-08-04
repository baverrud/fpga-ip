# ============================================================================
# sv-uvvm.f -- SystemVerilog + UVVM Verification File List
#
# Used by:
#   run axis_fifo modelsim sv-uvvm   (simulation, all sections)
#
# Section reference:
#   [rtl]   -- RTL sources (util_pkg + axis_fifo.sv)
#   [tb]    -- UVVM test harness + sequencer
#
# Notes:
#   - util_pkg (common/rtl/util_pkg.vhd) provides log2ceil for all VHDL cores.
#     Mixed-language simulators (ModelSim, Questa) handle transparently.
#   - UVVM is auto-detected by scanning [tb] file contents.
#   - Uses SystemVerilog core (axis_fifo.sv) instead of VHDL core.
#   - Synthesis: empty [top] section triggers a skip with clear message.
#     Use sv.f instead for synthesis.
# ============================================================================

# [rtl]
common/rtl/util_pkg.vhd
axis_fifo/rtl/axis_fifo.sv

# [top]

# [tb]
axis_fifo/tb/axis_fifo_uvvm_th.vhd
axis_fifo/tb/axis_fifo_uvvm_tb.vhd
