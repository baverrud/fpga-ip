# ============================================================================
# uvvm.f -- UVVM Verification File List (VHDL core)
#
# Used by:
#   run axis_skid_buffer uvvm modelsim    (simulation; requires UVVM)
#   run axis_skid_buffer uvvm questa      (simulation; requires UVVM)
#
# Section reference:
#   [rtl]        -- RTL sources
#   [tb:<name>]  -- UVVM test harness + sequencer
#
# Notes:
#   - UVVM testbench: top is the sequencer (axis_skid_buffer_uvvm_tb), time
#     resolution fs, and the run requires the UVVM libraries.
#   - Synthesis flows ignore this file. Use vhdl.f for synthesis.
# ============================================================================
DEFAULT_STD: 2008
DEFAULT_LIB: work

[rtl]
axis_skid_buffer/rtl/axis_skid_buffer.vhd

[tb:default]
top = axis_skid_buffer_uvvm_tb
requires = uvvm
time_res = fs
axis_skid_buffer/tb/axis_skid_buffer_uvvm_th.vhd
axis_skid_buffer/tb/axis_skid_buffer_uvvm_tb.vhd
