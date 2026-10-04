# ============================================================================
# vhdl.f -- AXI read bridge design and integration testbench file list
#
# Used by:
#   run axi_read_bridge vhdl modelsim       (simulation)
#   run axi_read_bridge vhdl vivado         (synthesis)
#
# The native-side memory slaves (axi_mem_store, axi_mem_model and their
# latency/jitter helpers) are simulation models, so they are listed in the
# tb sections only and never reach synthesis.
#
# default : comprehensive bench, axi_mem_store as the native slave
# model   : same bench, axi_mem_model (address-pattern slave) instead
# simple  : short hand-editable bench on axi_mem_store
#
# The comprehensive bench uses a 4.3 ns native clock, so it needs -t ps.
# ============================================================================
DEFAULT_STD: 2008
DEFAULT_LIB: work
DEFAULT_TB: default

[rtl]
common/rtl/util_pkg.vhd
axis_fifo_r/rtl/axis_fifo_r.vhd
axi_ar_mux/rtl/axi_ar_mux.vhd
axis_cdc/rtl/axis_cdc.vhd
axis_upsizer/rtl/axis_upsizer.vhd
axi_r_demux/rtl/axi_r_demux.vhd
axi_read_bridge/rtl/axi_read_bridge.vhd

[top]
axi_read_bridge/top/axi_read_bridge_top.vhd

[tb:default]
top = axi_read_bridge_tb
time_res = ps
parallel_prng/rtl/xorshift32.vhd
parallel_prng/rtl/xorshift128.vhd
jitter_gen/rtl/jitter_gen.vhd
axis_latency_gen/rtl/axis_latency_gen.vhd
axi_mem_model/rtl/axi_mem_model_core.vhd
axi_mem_model/rtl/axi_mem_model.vhd
axi_mem_store/rtl/axi_mem_store_core.vhd
axi_mem_store/rtl/axi_mem_store.vhd
axi_read_bridge/tb/axi_read_bridge_tb.vhd

[tb:model]
top = axi_read_bridge_tb
time_res = ps
generics = GC_USE_MEM_STORE=false
parallel_prng/rtl/xorshift32.vhd
parallel_prng/rtl/xorshift128.vhd
jitter_gen/rtl/jitter_gen.vhd
axis_latency_gen/rtl/axis_latency_gen.vhd
axi_mem_model/rtl/axi_mem_model_core.vhd
axi_mem_model/rtl/axi_mem_model.vhd
axi_mem_store/rtl/axi_mem_store_core.vhd
axi_mem_store/rtl/axi_mem_store.vhd
axi_read_bridge/tb/axi_read_bridge_tb.vhd

[tb:simple]
top = axi_read_bridge_simple_tb
parallel_prng/rtl/xorshift32.vhd
parallel_prng/rtl/xorshift128.vhd
jitter_gen/rtl/jitter_gen.vhd
axis_latency_gen/rtl/axis_latency_gen.vhd
axi_mem_store/rtl/axi_mem_store_core.vhd
axi_mem_store/rtl/axi_mem_store.vhd
axi_read_bridge/tb/axi_read_bridge_simple_tb.vhd
