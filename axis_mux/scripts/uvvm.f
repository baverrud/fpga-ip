# axis_mux UVVM VVC regression manifest
# The UVVM testbench uses three input masters and one output slave.
DEFAULT_STD: 2008
DEFAULT_LIB: work
DEFAULT_TB: default

[rtl]
common/rtl/util_pkg.vhd
axis_fifo/rtl/axis_fifo.vhd
axis_mux/rtl/axis_mux.vhd

[tb:default]
top = axis_mux_uvvm_tb
requires = uvvm
time_res = fs
axis_mux/tb/axis_mux_uvvm_th.vhd
axis_mux/tb/axis_mux_uvvm_tb.vhd

[tb:depth2]
top = axis_mux_uvvm_tb
requires = uvvm
time_res = fs
generics = GC_FIFO_DEPTH=2
axis_mux/tb/axis_mux_uvvm_th.vhd
axis_mux/tb/axis_mux_uvvm_tb.vhd

[tb:wide]
top = axis_mux_uvvm_tb
requires = uvvm
time_res = fs
generics = GC_TDATA_WIDTH=256, GC_FIFO_DEPTH=4
axis_mux/tb/axis_mux_uvvm_th.vhd
axis_mux/tb/axis_mux_uvvm_tb.vhd
