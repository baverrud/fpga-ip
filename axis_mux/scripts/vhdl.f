# axis_mux VHDL design, comprehensive/simple testbench, and synthesis manifest
DEFAULT_STD: 2008
DEFAULT_LIB: work
DEFAULT_TB: default

[rtl]
common/rtl/util_pkg.vhd
axis_fifo/rtl/axis_fifo.vhd
axis_mux/rtl/axis_mux.vhd

[top]
axis_mux/top/axis_mux_top.vhd

[tb:default]
top = axis_mux_tb
requires =
common/rtl/axis_bfm_pkg.vhd
axis_mux/tb/axis_mux_tb.vhd

[tb:simple]
top = axis_mux_simple_tb
requires =
common/rtl/axis_bfm_pkg.vhd
axis_mux/tb/axis_mux_simple_tb.vhd

[tb:single]
top = axis_mux_tb
generics = GC_NUM_INPUTS=1, GC_FIFO_DEPTH=2
requires =
common/rtl/axis_bfm_pkg.vhd
axis_mux/tb/axis_mux_tb.vhd

[tb:wide]
top = axis_mux_tb
generics = GC_TDATA_WIDTH=512, GC_FIFO_DEPTH=4
requires =
common/rtl/axis_bfm_pkg.vhd
axis_mux/tb/axis_mux_tb.vhd

[tb:depth2]
top = axis_mux_tb
generics = GC_FIFO_DEPTH=2
requires =
common/rtl/axis_bfm_pkg.vhd
axis_mux/tb/axis_mux_tb.vhd

[tb:many]
top = axis_mux_tb
generics = GC_NUM_INPUTS=8, GC_FIFO_DEPTH=8
requires =
common/rtl/axis_bfm_pkg.vhd
axis_mux/tb/axis_mux_tb.vhd
