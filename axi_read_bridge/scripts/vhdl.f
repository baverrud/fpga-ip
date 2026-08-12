# ============================================================================
# vhdl.f -- AXI read bridge design and integration testbench file list
#
# Used by:
#   run axi_read_bridge vhdl modelsim       (simulation)
#   run axi_read_bridge vhdl vivado         (synthesis)
# ============================================================================
DEFAULT_STD: 2008
DEFAULT_LIB: work
DEFAULT_TB: default

[rtl]
common/rtl/util_pkg.vhd
axis_fifo/rtl/axis_fifo.vhd
axi_ar_mux/rtl/axi_ar_mux.vhd
axis_cdc/rtl/axis_cdc.vhd
axis_upsizer/rtl/axis_upsizer.vhd
axi_r_demux/rtl/axi_r_demux.vhd
parallel_prng/rtl/xorshift32.vhd
parallel_prng/rtl/xorshift128.vhd
jitter_gen/rtl/jitter_gen.vhd
axis_latency_gen/rtl/axis_latency_gen.vhd
axi_mem_model/rtl/axi_mem_model_core.vhd
axi_mem_model/rtl/axi_mem_model.vhd
axi_read_bridge/rtl/axi_read_bridge.vhd

[top]
axi_read_bridge/rtl/axi_read_bridge_top.vhd

[constraints:vivado]
axi_read_bridge/constraints/axi_read_bridge.xdc

[tb:default]
top = axi_read_bridge_tb
axi_read_bridge/tb/axi_read_bridge_tb.vhd
