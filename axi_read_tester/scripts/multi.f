# ============================================================================
# multi.f — VHDL-2019 multi-shim + testbench file list
#
# Used by:
#   run axi_read_tester modelsim multi     (simulation, all sections)
#   run axi_read_tester vivado multi       (synthesis: [rtl] + [top] only)
#
# Section reference:
#   [rtl]   — RTL sources always compiled
#   [top]   — Top wrapper (synthesis only, not used in sim)
#   [tb]    — Testbench (simulation only, skipped in synthesis)
#
# Each line: <relative_path_from_sub_fpga_ip> [vhdl_std]
#   vhdl_std defaults to 2008 if omitted; set explicitly with "93", "2008", etc.
# ============================================================================

# [rtl]

# External AXI type packages (at sub/fpga-ip/common/rtl/)
common/rtl/axi4_pkg.vhd 2019
common/rtl/axilite_pkg.vhd 2019

# Shared IP support
common/rtl/util_pkg.vhd 2019
axis_fifo/rtl/axis_fifo.vhd 2019
parallel_prng/rtl/xorshift32.vhd 2019
parallel_prng/rtl/xorshift128.vhd 2019
jitter_gen/rtl/jitter_gen.vhd 2019
axis_latency_gen/rtl/axis_latency_gen.vhd 2019
axi_mem_model/rtl/axi_mem_model_core.vhd 2019
axi_mem_model/rtl/axi_mem_model.vhd 2019

# axilite_io register bridge
axilite_io/rtl/axilite_io_vhd.vhd 2019

# axi_read_tester core
axi_read_tester/rtl/axi_read_tester_ar_gen.vhd 2019
axi_read_tester/rtl/axi_read_tester_r_mon.vhd 2019
axi_read_tester/rtl/axi_read_tester.vhd 2019

# VHDL-2019 AXI4 mode-view shim
axi_read_tester/rtl/axi4_read_tester_shim.vhd 2019

# Multi-shim wrapper
axi_read_tester/rtl/axi4_read_tester_multi.vhd 2019

# [top]
# synthesis wrapper
axi_read_tester/rtl/axi4_read_tester_multi_top.vhd 2019

# [tb]
# Multi-shim testbench
axi_read_tester/tb/axi4_read_tester_multi_tb.vhd 2019
