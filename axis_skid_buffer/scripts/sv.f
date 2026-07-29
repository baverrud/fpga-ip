# ============================================================================
# sv.f — SystemVerilog Design & Simple Testbench File List
#
# Used by:
#   run axis_skid_buffer modelsim sv      (simulation, all sections)
#   run axis_skid_buffer vivado sv        (synthesis: [rtl] + [top] only)
#
# Section reference:
#   [rtl]   — RTL sources always compiled
#   [top]   — Top wrapper (synthesis only, not used in sim)
#   [tb]    — Testbench (simulation only, skipped in synthesis)
# ============================================================================

# [rtl]
axis_skid_buffer/rtl/axis_skid_buffer.sv

# [top]
axis_skid_buffer/rtl/axis_skid_buffer_top.vhd

# [tb]
axis_skid_buffer/tb/axis_skid_buffer_tb.vhd
