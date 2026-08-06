# ============================================================================
# sv-uvvm.f -- SystemVerilog + UVVM Verification File List
#
# Used by:
#   run axis_skid_buffer sv-uvvm modelsim  (simulation; requires UVVM)
#   run axis_skid_buffer sv-uvvm questa    (simulation; requires UVVM)
#
# Section reference:
#   [rtl]        -- RTL sources
#   [tb:<name>]  -- UVVM test harness + sequencer
#
# Notes:
#   - Uses SystemVerilog core (axis_skid_buffer.sv) instead of VHDL.
#   - Simulation-only manifest: no [top] section; use sv.f for synthesis.
# ============================================================================
DEFAULT_STD: 2008
DEFAULT_LIB: work

[rtl]
axis_skid_buffer/rtl/axis_skid_buffer.sv

[tb:default]
top = axis_skid_buffer_uvvm_tb
requires = uvvm
time_res = fs
axis_skid_buffer/tb/axis_skid_buffer_uvvm_th.vhd
axis_skid_buffer/tb/axis_skid_buffer_uvvm_tb.vhd
