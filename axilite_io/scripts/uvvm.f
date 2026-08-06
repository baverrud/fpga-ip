# ============================================================================
# uvvm.f -- UVVM Verification File List for axilite_io
#
# Used by:
#   run axilite_io uvvm modelsim      (simulation; requires UVVM)
#   run axilite_io uvvm questa        (simulation; requires UVVM)
#
# Section reference:
#   [rtl]        -- RTL sources
#   [tb:<name>]  -- UVVM test harness + sequencer
#
# Notes:
#   - UVVM testbench: top is the sequencer (axilite_io_uvvm_tb), time
#     resolution fs, and the run requires the UVVM libraries.
#   - Synthesis flows ignore this file. Use vhdl.f for synthesis.
# ============================================================================
DEFAULT_STD: 2008
DEFAULT_LIB: work

[rtl]
common/rtl/util_pkg.vhd
axilite_io/rtl/axilite_io.vhd

[tb:default]
top = axilite_io_uvvm_tb
requires = uvvm
time_res = fs
axilite_io/tb/axilite_io_wrap.vhd
axis_fifo/rtl/axis_fifo.vhd
axilite_io/tb/axilite_io_harness.vhd
axilite_io/tb/axilite_io_th.vhd
common/rtl/axilite_bfm_pkg.vhd
axilite_io/tb/axilite_io_uvvm_th.vhd
axilite_io/tb/axilite_io_uvvm_tb.vhd
