# ============================================================================
# uvvm.f -- UVVM Verification File List (language-agnostic)
#
# Used by:
#   run axis_fifo uvvm modelsim      (simulation; requires UVVM)
#   run axis_fifo uvvm questa        (simulation; requires UVVM)
#
# Section reference:
#   [rtl]        -- RTL sources (shared with vhdl.f)
#   [tb:<name>]  -- UVVM test harness + sequencer
#
# Notes:
#   - UVVM testbench: top is the sequencer (axis_fifo_uvvm_tb), time
#     resolution fs, and the run requires the UVVM libraries.
#   - Synthesis flows ignore this file (no [top] section, UVVM libs are
#     simulation-only). Use vhdl.f or sv.f for synthesis.
# ============================================================================
DEFAULT_STD: 2008
DEFAULT_LIB: work

[rtl]
common/rtl/util_pkg.vhd
axis_fifo/rtl/axis_fifo.vhd

[tb:default]
top = axis_fifo_uvvm_tb
requires = uvvm
time_res = fs
axis_fifo/tb/axis_fifo_uvvm_th.vhd
axis_fifo/tb/axis_fifo_uvvm_tb.vhd
