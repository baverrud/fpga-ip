# ============================================================================
# shim.f -- VHDL-2019 AXI4 mode-view shim + testbench file list
#
# NOTE: The run.bat / simulate.bat flow does not support VHDL-2019 files.
#       Compile and simulate manually with a simulator that supports
#       VHDL-2019 mode views, after environment setup:
#
#   cd sub/fpga-ip
#   cd axi_read_tester
#   vlib work
#   vcom -2019 -work work ../common/rtl/axi4_pkg.vhd
#   vcom -2019 -work work ../common/rtl/axilite_pkg.vhd
#   for %f in (../common/rtl/util_pkg.vhd ../axis_fifo/rtl/*.vhd
#              ../parallel_prng/rtl/*.vhd ../jitter_gen/rtl/*.vhd
#              ../axis_latency_gen/rtl/*.vhd ../axi_mem_model/rtl/*.vhd) do vcom -2019 -work work %f
#   vcom -2019 -work work rtl/axi_read_tester_ar_gen.vhd
#   vcom -2019 -work work rtl/axi_read_tester_r_mon.vhd
#   vcom -2019 -work work rtl/axi_read_tester.vhd
#   vcom -2019 -work work rtl/axi4_read_tester_shim.vhd
#   vcom -2019 -work work rtl/axi4_read_tester_shim_top.vhd
#   vcom -2019 -work work tb/axi4_read_tester_shim_tb.vhd
#   vsim -voptargs=+acc work.axi4_read_tester_shim_tb
#   run -all
#
# All paths are relative to sub/fpga-ip/
#
# Section reference:
#   [rtl]   -- RTL sources always compiled
#   [tb]    -- Testbench (simulation only, defines top entity)
#
# Note: compile all listed files as VHDL-2019 to avoid mixed-standard
# elaboration issues in simulators that reject mixed versions.
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

# axilite_io register bridge (package merged into util_pkg)
axilite_io/rtl/axilite_io.vhd 2019

# axi_read_tester core
axi_read_tester/rtl/axi_read_tester_ar_gen.vhd 2019
axi_read_tester/rtl/axi_read_tester_r_mon.vhd 2019
axi_read_tester/rtl/axi_read_tester.vhd 2019

# VHDL-2019 AXI4 mode-view shim
axi_read_tester/rtl/axi4_read_tester_shim.vhd 2019

# [top]
# synthesis wrapper
axi_read_tester/rtl/axi4_read_tester_shim_top.vhd 2019

# [tb]
# AXI4-Lite BFM testbench
axi_read_tester/tb/axi4_read_tester_shim_tb.vhd 2019
