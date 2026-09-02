# ============================================================================
# sv.f -- Mixed-language axis_cdc synthesis manifest
#
# Used by:
#   run axis_cdc sv vivado
#
# Compiles the VHDL axis_cdc core and synthesizes the SystemVerilog wrapper.
# This verifies mixed-language generic/parameter and port binding.
# ============================================================================
DEFAULT_STD: 2008
DEFAULT_LIB: work

[rtl]
common/rtl/util_pkg.vhd
axis_cdc/rtl/axis_cdc.vhd

[top]
top = axis_cdc_top
axis_cdc/top/axis_cdc_top.sv
