# ============================================================================
# vhdl.f -- VHDL Design & Testbench File List
#
# Used by:
#   run axi_ar_mux vhdl modelsim   (simulation: [rtl] + [tb:default])
#   run axi_ar_mux vhdl vivado     (synthesis: [rtl] + [top] only)
#   run axi_ar_mux vhdl xsim       (XSim simulation)
#
# Section reference:
#   [rtl]        -- RTL sources always compiled (dependencies first)
#   [top]        -- Top wrapper (synthesis only, not used in sim)
#   [tb:<name>]  -- Testbench (simulation only, skipped in synthesis)
#
# Each line: <relative_path_from_sub_fpga_ip> [std=<vhdl_std>]
#   vhdl_std defaults to DEFAULT_STD (2008) if omitted.
#
# axi_ar_mux depends on util_pkg (log2ceil and array types), listed first.
# ============================================================================
DEFAULT_STD: 2008
DEFAULT_LIB: work
DEFAULT_TB: default

[rtl]
common/rtl/util_pkg.vhd
axi_ar_mux/rtl/axi_ar_mux.vhd

[top]
axi_ar_mux/top/axi_ar_mux_top.vhd

[tb:default]
top = axi_ar_mux_tb
axi_ar_mux/tb/axi_ar_mux_tb.vhd

[tb:depth32]
top = axi_ar_mux_tb
generics = GC_FIFO_DEPTH=32
axi_ar_mux/tb/axi_ar_mux_tb.vhd

[tb:c1]
top = axi_ar_mux_tb
generics = GC_NUM_CLIENTS=1, GC_ID_WIDTH=1, GC_FIFO_DEPTH=4
axi_ar_mux/tb/axi_ar_mux_tb.vhd

[tb:c2]
top = axi_ar_mux_tb
generics = GC_NUM_CLIENTS=2, GC_ID_WIDTH=1, GC_FIFO_DEPTH=4
axi_ar_mux/tb/axi_ar_mux_tb.vhd

[tb:c3]
top = axi_ar_mux_tb
generics = GC_NUM_CLIENTS=3, GC_ID_WIDTH=2, GC_FIFO_DEPTH=4
axi_ar_mux/tb/axi_ar_mux_tb.vhd

[tb:small]
top = axi_ar_mux_tb
generics = GC_FIFO_DEPTH=4
axi_ar_mux/tb/axi_ar_mux_tb.vhd

[tb:min2]
top = axi_ar_mux_tb
generics = GC_FIFO_DEPTH=2
axi_ar_mux/tb/axi_ar_mux_tb.vhd

[tb:nonpow5]
top = axi_ar_mux_tb
generics = GC_FIFO_DEPTH=5
axi_ar_mux/tb/axi_ar_mux_tb.vhd

[tb:wide]
top = axi_ar_mux_tb
generics = GC_NUM_CLIENTS=8, GC_ID_WIDTH=4, GC_FIFO_DEPTH=8
axi_ar_mux/tb/axi_ar_mux_tb.vhd

[tb:ratio2]
top = axi_ar_mux_tb
generics = GC_R_BEATS_PER_POP=2
axi_ar_mux/tb/axi_ar_mux_tb.vhd

[tb:ratio3]
top = axi_ar_mux_tb
generics = GC_R_BEATS_PER_POP=3
axi_ar_mux/tb/axi_ar_mux_tb.vhd

[tb:maxlen]
top = axi_ar_mux_tb
generics = GC_NUM_CLIENTS=1, GC_ID_WIDTH=1, GC_FIFO_DEPTH=256
axi_ar_mux/tb/axi_ar_mux_tb.vhd
