# ============================================================================
# uvvm_util.f — Direct axis_fifo testbench using uvvm_util only
#
# Used by:
#   run axis_fifo modelsim uvvm_util   (simulation, all sections)
#   run axis_fifo xsim uvvm_util       (simulation, all sections)
#
# Section reference:
#   [rtl]   — RTL sources shared with the standard VHDL flow
#   [tb]    — Direct DUT testbench using uvvm_util only
#
# Notes:
#   - This flow intentionally does NOT reference uvvm_vvc_framework.
#   - The testbench entity is still axis_fifo_tb so the generic launchers
#     can reuse their default work.axis_fifo_tb top-name convention.
#   - The purpose of this file list is to probe whether XSim can run a test
#     using uvvm_util alone, without the VVC framework.
# ============================================================================

# [rtl]
common/rtl/util_pkg.vhd
axis_fifo/rtl/axis_fifo.vhd

# [tb]
axis_fifo/tb/axis_fifo_tb_bfm_pkg.vhd
axis_fifo/tb/axis_fifo_uvvm_util_tb.vhd