# ============================================================================
# sv.f -- SystemVerilog Design & Simple Testbench File List
#
# Used by:
#   run axis_skid_buffer sv modelsim      (simulation: [rtl] + [tb:default])
#   run axis_skid_buffer sv vivado        (synthesis: [rtl] + [top] only)
#
# Section reference:
#   [rtl]        -- RTL sources always compiled
#   [top]        -- Top wrapper (synthesis only, not used in sim)
#   [tb:<name>]  -- Testbench (simulation only, skipped in synthesis)
# ============================================================================
DEFAULT_STD: 2008
DEFAULT_LIB: work

[rtl]
axis_skid_buffer/rtl/axis_skid_buffer.sv

[top]
axis_skid_buffer/top/axis_skid_buffer_top.vhd

[tb:default]
top = axis_skid_buffer_tb
time_res = ps
common/rtl/axis_bfm_pkg.vhd
axis_skid_buffer/tb/axis_skid_buffer_tb.vhd
