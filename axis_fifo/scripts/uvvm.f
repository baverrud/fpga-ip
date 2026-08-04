# ============================================================================
# uvvm.f -- UVVM Verification File List (language-agnostic)
#
# Used by:
#   run axis_fifo modelsim uvvm      (simulation, all sections)
#
# Section reference:
#   [rtl]   -- RTL sources (shared with vhdl.f)
#   [tb]    -- UVVM test harness + sequencer
#
# Notes:
#   - The basename "uvvm" triggers auto-detection in sim_modelsim.do:
#     top entity becomes axis_fifo_uvvm_tb, time resolution set to fs.
#   - Synthesis flows ignore this file (no [top] section, UVVM libs
#     are simulation-only). Use vhdl.f or sv.f for synthesis.
# ============================================================================

# [rtl]
common/rtl/util_pkg.vhd
axis_fifo/rtl/axis_fifo.vhd

# [tb]
axis_fifo/tb/axis_fifo_uvvm_th.vhd
axis_fifo/tb/axis_fifo_uvvm_tb.vhd
