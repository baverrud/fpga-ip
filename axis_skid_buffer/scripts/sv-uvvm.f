# ============================================================================
# sv-uvvm.f -- SystemVerilog + UVVM Verification File List
#
# Used by:
#   run axis_skid_buffer modelsim sv-uvvm  (simulation, all sections)
#
# Section reference:
#   [rtl]   -- RTL sources
#   [top]   -- Empty (synthesis gracefully skips)
#   [tb]    -- UVVM test harness + sequencer
#
# Notes:
#   - Uses SystemVerilog core (axis_skid_buffer.sv) instead of VHDL.
#   - UVVM is auto-detected by scanning [tb] file contents.
#   - For synthesis, use sv.f instead.
# ============================================================================

# [rtl]
axis_skid_buffer/rtl/axis_skid_buffer.sv

# [top]

# [tb]
axis_skid_buffer/tb/axis_skid_buffer_uvvm_th.vhd
axis_skid_buffer/tb/axis_skid_buffer_uvvm_tb.vhd
