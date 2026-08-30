# ============================================================================
# uvvm.f -- axis_cdc UVVM VVC regression manifest
#
# Used by:
#   run axis_cdc uvvm modelsim
#   run axis_cdc uvvm modelsim --tb all
#   run axis_cdc uvvm questa --tb all
#
# Full-VVC simulation only. XSim does not provide the UVVM libraries.
# ============================================================================
DEFAULT_STD: 2008
DEFAULT_LIB: work
DEFAULT_TB: default

[rtl]
common/rtl/util_pkg.vhd
axis_cdc/rtl/axis_cdc.vhd

[tb:default]
top = axis_cdc_uvvm_tb
requires = uvvm
time_res = fs
axis_cdc/tb/axis_cdc_uvvm_th.vhd
axis_cdc/tb/axis_cdc_uvvm_tb.vhd

[tb:rev]
top = axis_cdc_uvvm_tb
requires = uvvm
time_res = fs
generics = GC_S_CLK_PERIOD=13.2ns, GC_M_CLK_PERIOD=10ns
axis_cdc/tb/axis_cdc_uvvm_th.vhd
axis_cdc/tb/axis_cdc_uvvm_tb.vhd

[tb:depth2]
top = axis_cdc_uvvm_tb
requires = uvvm
time_res = fs
generics = GC_CDC_DEPTH=2
axis_cdc/tb/axis_cdc_uvvm_th.vhd
axis_cdc/tb/axis_cdc_uvvm_tb.vhd

[tb:sync4]
top = axis_cdc_uvvm_tb
requires = uvvm
time_res = fs
generics = GC_SYNC_STAGES=4
axis_cdc/tb/axis_cdc_uvvm_th.vhd
axis_cdc/tb/axis_cdc_uvvm_tb.vhd

[tb:equal]
top = axis_cdc_uvvm_tb
requires = uvvm
time_res = fs
generics = GC_S_CLK_PERIOD=10ns, GC_M_CLK_PERIOD=10ns
axis_cdc/tb/axis_cdc_uvvm_th.vhd
axis_cdc/tb/axis_cdc_uvvm_tb.vhd

[tb:fast_source]
top = axis_cdc_uvvm_tb
requires = uvvm
time_res = fs
generics = GC_S_CLK_PERIOD=2ns, GC_M_CLK_PERIOD=20ns
axis_cdc/tb/axis_cdc_uvvm_th.vhd
axis_cdc/tb/axis_cdc_uvvm_tb.vhd

[tb:fast_destination]
top = axis_cdc_uvvm_tb
requires = uvvm
time_res = fs
generics = GC_S_CLK_PERIOD=20ns, GC_M_CLK_PERIOD=2ns
axis_cdc/tb/axis_cdc_uvvm_th.vhd
axis_cdc/tb/axis_cdc_uvvm_tb.vhd

[tb:stress]
top = axis_cdc_uvvm_tb
requires = uvvm
time_res = fs
# NOTE: 256-bit is the maximum TDATA the UVVM AXI-Stream VIP supports with
# this precompiled library (TSTRB is capped at C_AXISTREAM_BFM_MAX_TSTRB_BITS=32
# in uvvm_util/src/adaptations_pkg.vhd). A 512-bit UVVM stress is impossible;
# use the direct testbench (scripts/vhdl.f, [tb:stress]) for 512-bit coverage.
generics = GC_TDATA_WIDTH=256, GC_SYNC_STAGES=4, GC_S_CLK_PERIOD=2ns, GC_M_CLK_PERIOD=20ns
axis_cdc/tb/axis_cdc_uvvm_th.vhd
axis_cdc/tb/axis_cdc_uvvm_tb.vhd
