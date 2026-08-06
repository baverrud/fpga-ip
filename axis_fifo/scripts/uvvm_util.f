# ============================================================================
# uvvm_util.f -- Direct axis_fifo testbench using uvvm_util only
#
# Used by:
#   run axis_fifo uvvm_util modelsim   (simulation; requires UVVM libs)
#   run axis_fifo uvvm_util questa     (simulation; requires UVVM libs)
#
# Section reference:
#   [rtl]        -- RTL sources shared with the standard VHDL flow
#   [tb:<name>]  -- Direct DUT testbench using uvvm_util only
#
# Notes:
#   - This flow intentionally does NOT reference uvvm_vvc_framework; it uses
#     the uvvm_util library only.
#   - The testbench entity is axis_fifo_tb (see axis_fifo_uvvm_util_tb.vhd).
#   - Requires the UVVM libraries, so XSim (which has none) skips it.
# ============================================================================
DEFAULT_STD: 2008
DEFAULT_LIB: work

[rtl]
common/rtl/util_pkg.vhd
axis_fifo/rtl/axis_fifo.vhd

[tb:default]
top = axis_fifo_tb
requires = uvvm
time_res = fs
common/rtl/axis_bfm_pkg.vhd
axis_fifo/tb/axis_fifo_uvvm_util_tb.vhd