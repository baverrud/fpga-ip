# ============================================================================
# vhdl.f -- VHDL Design & Testbench File List
#
# Used by:
#   run axi_mem_image vhdl modelsim    (simulation: [rtl] + [tb:default])
#   run axi_mem_image vhdl xsim        (XSim simulation)
#
# Section reference:
#   [rtl]        -- RTL sources always compiled
#   [tb:<name>]  -- Testbench (simulation only, skipped in synthesis)
#
# Simulation-only IP: mem_image loads Intel HEX images through textio, which
# cannot be synthesised.  There is deliberately no [top] section, so the
# synthesis flows report this manifest as skipped instead of trying to build
# it.
#
# Each line: <relative_path_from_sub_fpga_ip> [std=<vhdl_std>]
#   vhdl_std defaults to DEFAULT_STD (2008) if omitted.
# ============================================================================
DEFAULT_STD: 2008
DEFAULT_LIB: work
DEFAULT_TB: default

[rtl]
common/rtl/util_pkg.vhd
axis_fifo/rtl/axis_fifo.vhd
parallel_prng/rtl/xorshift32.vhd
parallel_prng/rtl/xorshift128.vhd
jitter_gen/rtl/jitter_gen.vhd
axis_latency_gen/rtl/axis_latency_gen.vhd
axi_ar_mux/rtl/axi_ar_mux.vhd
axis_cdc/rtl/axis_cdc.vhd
axis_upsizer/rtl/axis_upsizer.vhd
axi_r_demux/rtl/axi_r_demux.vhd
axi_mem_image/rtl/mem_image_pkg.vhd
axi_mem_image/rtl/mem_image.vhd
axi_mem_image/rtl/axi_mem_image_core.vhd
axi_mem_image/rtl/axi_mem_image.vhd
axi_read_bridge/rtl/axi_read_bridge.vhd

[tb:default]
top = mem_image_tb
axi_mem_image/tb/mem_image_tb.vhd

[tb:examples]
top = mem_image_examples_tb
axi_mem_image/tb/mem_image_examples_tb.vhd

[tb:simple]
top = mem_image_simple_tb
axi_mem_image/tb/mem_image_simple_tb.vhd

[tb:corner]
top = mem_image_corner_tb
axi_mem_image/tb/mem_image_corner_tb.vhd

[tb:bridge]
top = axi_mem_image_bridge_tb
axi_mem_image/tb/axi_mem_image_bridge_tb.vhd
