# ============================================================================
# multi.f -- VHDL-2019 multi-shim + testbench file list
#
# Used by:
#   run axi_read_tester multi questa     (simulation; Questa 2025.3 for VHDL-2019)
#   run axi_read_tester multi vivado     (synthesis: [rtl] + [top] only)
#
# Section reference:
#   [rtl]        -- RTL sources always compiled
#   [top]        -- Top wrapper (synthesis only, not used in sim)
#   [tb:<name>]  -- Testbench (simulation only, skipped in synthesis)
#
# Each line: <relative_path_from_sub_fpga_ip> [std=<vhdl_std>]
#   All files are VHDL-2019 (DEFAULT_STD). Mixed-standard elaboration is not
#   supported by Questa, so everything must stay at 2019.
# ============================================================================
DEFAULT_STD: 2019
DEFAULT_LIB: work

[rtl]
# External AXI type packages (at sub/fpga-ip/common/rtl/)
common/rtl/axi4_pkg.vhd
common/rtl/axilite_pkg.vhd

# Shared IP support
common/rtl/util_pkg.vhd
axis_fifo/rtl/axis_fifo.vhd
parallel_prng/rtl/xorshift32.vhd
parallel_prng/rtl/xorshift128.vhd
jitter_gen/rtl/jitter_gen.vhd
axis_latency_gen/rtl/axis_latency_gen.vhd
axi_mem_model/rtl/axi_mem_model_core.vhd
axi_mem_model/rtl/axi_mem_model.vhd

# axilite_io register bridge
axilite_io/rtl/axilite_io.vhd

# axi_read_tester core
axi_read_tester/rtl/axi_read_tester_ar_gen.vhd
axi_read_tester/rtl/axi_read_tester_r_mon.vhd
axi_read_tester/rtl/axi_read_tester.vhd

# VHDL-2019 AXI4 mode-view shim
axi_read_tester/rtl/axi4_read_tester_shim.vhd

# Multi-shim wrapper
axi_read_tester/rtl/axi4_read_tester_multi.vhd

[top]
# synthesis wrapper
axi_read_tester/rtl/axi4_read_tester_multi_top.vhd

[tb:default]
top = axi4_read_tester_multi_tb
# Multi-shim testbench
axi_read_tester/tb/axi4_read_tester_multi_tb.vhd
