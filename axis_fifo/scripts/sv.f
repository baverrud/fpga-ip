# axis_fifo SystemVerilog manifest
DEFAULT_STD: 2008
DEFAULT_LIB: work

[rtl]
common/rtl/util_pkg.vhd
axis_fifo/rtl/axis_fifo.sv

[top]
axis_fifo/rtl/axis_fifo_top.vhd

[tb:default]
top = axis_fifo_tb
requires =
axis_fifo/tb/axis_fifo_tb_bfm_pkg.vhd
axis_fifo/tb/axis_fifo_tb.vhd