# ============================================================================
# vhdl.f -- axi_traffic_gen VHDL RTL & Testbench File List
#
# Used by:
#   run axi_traffic_gen vhdl modelsim       (simulation; default tb: default)
#   run axi_traffic_gen vhdl modelsim --tb simple   (hand-editable skeleton)
#   run axi_traffic_gen vhdl vivado         (synthesis: [rtl] + [top] only)
#   run axi_traffic_gen vhdl xsim           (XSim simulation)
#
# Section reference:
#   [rtl]        -- RTL sources always compiled
#   [top]        -- Synthesis top: metadata line 'top = <entity>' when the
#                   top is a regular [rtl] source (no wrapper needed)
#   [tb:<name>]  -- Testbench (simulation only, skipped in synthesis)
#
# Each line: <relative_path_from_sub_fpga_ip> [std=<vhdl_std>]
#   vhdl_std defaults to DEFAULT_STD (2008) if omitted.
# ============================================================================
DEFAULT_STD: 2008
DEFAULT_LIB: work
DEFAULT_TB: default

[rtl]
common/rtl/util_pkg.vhd
parallel_prng/rtl/xorshift128.vhd
axi_traffic_gen/rtl/axi_ar_gen.vhd

[top]
top = axi_ar_gen

[tb:default]
top = axi_ar_gen_tb
axi_traffic_gen/tb/axi_ar_gen_tb.vhd

[tb:simple]
top = axi_ar_gen_simple_tb
axi_traffic_gen/tb/axi_ar_gen_simple_tb.vhd
