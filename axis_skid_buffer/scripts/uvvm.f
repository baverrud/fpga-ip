# ============================================================================
# uvvm.f -- UVVM Verification File List (VHDL core)
#
# Used by:
#   run axis_skid_buffer modelsim uvvm    (simulation, all sections)
#
# Section reference:
#   [rtl]   -- RTL sources
#   [tb]    -- UVVM test harness + sequencer
#
# Notes:
#   - Basename "uvvm" triggers auto-detection in sim_modelsim.do:
#     top entity becomes axis_skid_buffer_uvvm_tb, time resolution set to fs.
#   - Synthesis flows ignore this file. Use vhdl.f for synthesis.
# ============================================================================

# [rtl]
axis_skid_buffer/rtl/axis_skid_buffer.vhd

# [tb]
axis_skid_buffer/tb/axis_skid_buffer_uvvm_th.vhd
axis_skid_buffer/tb/axis_skid_buffer_uvvm_tb.vhd
