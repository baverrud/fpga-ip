# ============================================================================
# vhdl.f -- VHDL design, wrapper and testbench file list
#
# Both AR and R paths use the shared axis_latency_gen.
# ============================================================================
DEFAULT_STD: 2008
DEFAULT_LIB: work
DEFAULT_TB: default

[rtl]
common/rtl/util_pkg.vhd
axis_fifo_r/rtl/axis_fifo_r.vhd
parallel_prng/rtl/xorshift32.vhd
parallel_prng/rtl/xorshift128.vhd
jitter_gen/rtl/jitter_gen.vhd
axis_latency_gen/rtl/axis_latency_gen.vhd
axi_mem_store/rtl/axi_mem_store_core.vhd
axi_mem_store/rtl/axi_mem_store.vhd

[top]
axi_mem_store/top/axi_mem_store_top.vhd

[tb:default]
top = axi_mem_store_tb
common/rtl/axis_bfm_pkg.vhd
axi_mem_store/tb/axi_mem_store_tb.vhd

[tb:simple]
top = axi_mem_store_simple_tb
common/rtl/axis_bfm_pkg.vhd
axi_mem_store/tb/axi_mem_store_simple_tb.vhd

[tb:wide]
top = axi_mem_store_wide_tb
common/rtl/axis_bfm_pkg.vhd
axi_mem_store/tb/axi_mem_store_wide_tb.vhd
