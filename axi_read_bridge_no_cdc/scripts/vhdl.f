# ============================================================================
# vhdl.f -- Single-clock, direct 512-bit AXI read bridge
# ============================================================================
DEFAULT_STD: 2008
DEFAULT_LIB: work
DEFAULT_TB: default

[rtl]
common/rtl/util_pkg.vhd
axis_fifo_r/rtl/axis_fifo_r.vhd
axi_ar_mux/rtl/axi_ar_mux.vhd
axi_r_demux/rtl/axi_r_demux.vhd
axi_read_bridge_no_cdc/rtl/axi_read_bridge_no_cdc.vhd

[top]
axi_read_bridge_no_cdc/top/axi_read_bridge_no_cdc_top.vhd

[tb:default]
top = axi_read_bridge_no_cdc_tb
axi_read_bridge_no_cdc/top/axi_read_bridge_no_cdc_top.vhd
parallel_prng/rtl/xorshift32.vhd
parallel_prng/rtl/xorshift128.vhd
jitter_gen/rtl/jitter_gen.vhd
axis_latency_gen/rtl/axis_latency_gen.vhd
axi_mem_model/rtl/axi_mem_model_core.vhd
axi_mem_model/rtl/axi_mem_model.vhd
axi_read_bridge_no_cdc/tb/axi_read_bridge_no_cdc_tb.vhd

[tb:simple]
top = axi_read_bridge_no_cdc_simple_tb
axi_read_bridge_no_cdc/top/axi_read_bridge_no_cdc_top.vhd
parallel_prng/rtl/xorshift32.vhd
parallel_prng/rtl/xorshift128.vhd
jitter_gen/rtl/jitter_gen.vhd
axis_latency_gen/rtl/axis_latency_gen.vhd
axi_mem_model/rtl/axi_mem_model_core.vhd
axi_mem_model/rtl/axi_mem_model.vhd
axi_read_bridge_no_cdc/tb/axi_read_bridge_no_cdc_simple_tb.vhd