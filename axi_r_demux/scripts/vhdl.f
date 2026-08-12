# ============================================================================
# vhdl.f -- VHDL Design & Testbench File List
#
# Used by:
#   run axi_r_demux vhdl modelsim   (simulation: [rtl] + [tb:default])
#   run axi_r_demux vhdl vivado     (synthesis: [rtl] + [top] only)
#   run axi_r_demux vhdl xsim       (XSim simulation)
#
# Section reference:
#   [rtl]        -- RTL sources always compiled (dependencies first)
#   [top]        -- Top wrapper (synthesis only, not used in sim)
#   [tb:<name>]  -- Testbench (simulation only, skipped in synthesis)
#
# Each line: <relative_path_from_sub_fpga_ip> [std=<vhdl_std>]
#   vhdl_std defaults to DEFAULT_STD (2008) if omitted.
#
# axi_r_demux depends on axis_fifo (per-client elastic buffers) and
# util_pkg (used by axis_fifo), so those are listed first in [rtl].
# ============================================================================
DEFAULT_STD: 2008
DEFAULT_LIB: work
DEFAULT_TB: default

[rtl]
common/rtl/util_pkg.vhd
axis_fifo/rtl/axis_fifo.vhd
axi_r_demux/rtl/axi_r_demux.vhd

[top]
axi_r_demux/rtl/axi_r_demux_top.vhd

[constraints:vivado]
axi_r_demux/constraints/axi_r_demux.xdc

[tb:default]
top = axi_r_demux_tb
axi_r_demux/tb/axi_r_demux_tb.vhd

[tb:c1]
top = axi_r_demux_small_tb
generics = GC_NUM_CLIENTS=1, GC_ID_WIDTH=1, GC_FIFO_DEPTH=4
axi_r_demux/tb/axi_r_demux_small_tb.vhd

[tb:c2]
top = axi_r_demux_small_tb
generics = GC_NUM_CLIENTS=2, GC_ID_WIDTH=1, GC_FIFO_DEPTH=4
axi_r_demux/tb/axi_r_demux_small_tb.vhd

[tb:c3]
top = axi_r_demux_small_tb
generics = GC_NUM_CLIENTS=3, GC_ID_WIDTH=2, GC_FIFO_DEPTH=4
axi_r_demux/tb/axi_r_demux_small_tb.vhd

[tb:w8]
top = axi_r_demux_tb
generics = GC_DATA_BYTES=1, GC_FIFO_DEPTH=8
axi_r_demux/tb/axi_r_demux_tb.vhd

[tb:w16]
top = axi_r_demux_tb
generics = GC_DATA_BYTES=2, GC_FIFO_DEPTH=8
axi_r_demux/tb/axi_r_demux_tb.vhd

[tb:w64]
top = axi_r_demux_tb
generics = GC_DATA_BYTES=8, GC_FIFO_DEPTH=8
axi_r_demux/tb/axi_r_demux_tb.vhd

[tb:w128]
top = axi_r_demux_tb
generics = GC_DATA_BYTES=16, GC_FIFO_DEPTH=8
axi_r_demux/tb/axi_r_demux_tb.vhd

[tb:small]
top = axi_r_demux_tb
generics = GC_FIFO_DEPTH=4
axi_r_demux/tb/axi_r_demux_tb.vhd

[tb:wide]
top = axi_r_demux_tb
generics = GC_NUM_CLIENTS=8, GC_DATA_BYTES=8, GC_FIFO_DEPTH=8
axi_r_demux/tb/axi_r_demux_tb.vhd
