# ============================================================================
# uvvm.f — UVVM Verification File List for axilite_io
#
# Used by:
#   run axilite_io uvvm modelsim      (simulation, all sections)
#
# Section reference:
#   [rtl]   — RTL sources
#   [tb]    — UVVM test harness + sequencer
#
# Notes:
#   - Basename "uvvm" triggers auto-detection in sim_modelsim.do:
#     top entity becomes axilite_io_uvvm_tb, time resolution set to fs.
#   - Synthesis flows ignore this file. Use vhdl.f for synthesis.
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
axilite_io/tb/axilite_io_uvvm_th.vhd
axilite_io/tb/axilite_io_uvvm_tb.vhd
