# axis_fifo_r SystemVerilog manifest
DEFAULT_STD: 2008
DEFAULT_LIB: work

[rtl]
common/rtl/util_pkg.vhd
axis_fifo_r/rtl/axis_fifo_r.sv

[top]
axis_fifo_r/top/axis_fifo_top.vhd

[tb:default]
top = axis_fifo_tb
requires =
time_res = ps
common/rtl/axis_bfm_pkg.vhd
axis_fifo_r/tb/axis_fifo_tb.vhd