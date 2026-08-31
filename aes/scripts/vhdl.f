# ============================================================================
# vhdl.f -- AES package and configurable AXI-Stream core
#
# Used by:
#   run aes vhdl modelsim     (simulation: [rtl] + selected [tb])
#   run aes vhdl vivado       (synthesis: [rtl] + [top] only)
#
# Section reference:
#   [rtl]        -- RTL sources always compiled
#   [top]        -- Synthesis top (not applicable to package/core bring-up)
#   [tb:<name>]  -- Testbench sources, simulation only
#
# Each line: <relative_path_from_sub_fpga_ip> [std=<vhdl_std>]
# ============================================================================
DEFAULT_STD: 2008
DEFAULT_LIB: work
DEFAULT_TB: default

[rtl]
aes/rtl/aes_pkg.vhd
aes/rtl/aes.vhd

[tb:default]
top = aes_tb
aes/tb/aes_tb.vhd

[tb:pkg]
top = aes_pkg_tb
aes/tb/aes_pkg_tb.vhd

[tb:simple]
top = aes_simple_tb
aes/tb/aes_simple_tb.vhd
