# ============================================================================
# vhdl.f -- VHDL Design & Testbench File List
#
# Used by:
#   run axis_downsizer vhdl modelsim   (simulation: [rtl] + [tb:<name>])
#   run axis_downsizer vhdl vivado     (synthesis: [rtl] + [top] only)
#   run axis_downsizer vhdl xsim       (XSim simulation)
#
# Section reference:
#   [rtl]        -- RTL sources always compiled
#   [top]        -- Top wrapper (synthesis only, not used in sim)
#   [tb:<name>]  -- Testbench (simulation only, skipped in synthesis)
#
# Each line: <relative_path_from_sub_fpga_ip> [std=<vhdl_std>]
#   vhdl_std defaults to DEFAULT_STD (2008) if omitted.
# ============================================================================
DEFAULT_STD: 2008
DEFAULT_LIB: work
DEFAULT_TB: default

[rtl]
axis_downsizer/rtl/axis_downsizer.vhd

[top]
axis_downsizer/rtl/axis_downsizer_top.vhd

[tb:default]
top = axis_downsizer_tb
axis_downsizer/tb/axis_downsizer_tb.vhd

[tb:narrow]
top = axis_downsizer_tb
generics = GC_M_WIDTH=8, GC_RATIO=4, GC_ID_WIDTH=4
axis_downsizer/tb/axis_downsizer_tb.vhd

[tb:x2]
top = axis_downsizer_tb
generics = GC_RATIO=2, GC_ID_WIDTH=4
axis_downsizer/tb/axis_downsizer_tb.vhd

[tb:pass]
top = axis_downsizer_tb
generics = GC_RATIO=1, GC_ID_WIDTH=1
axis_downsizer/tb/axis_downsizer_tb.vhd

[tb:x3]
top = axis_downsizer_tb
generics = GC_RATIO=3, GC_ID_WIDTH=3
axis_downsizer/tb/axis_downsizer_tb.vhd

[tb:x8]
top = axis_downsizer_tb
generics = GC_RATIO=8, GC_ID_WIDTH=6
axis_downsizer/tb/axis_downsizer_tb.vhd

[tb:small]
top = axis_downsizer_tb
generics = GC_M_WIDTH=4, GC_RATIO=2, GC_ID_WIDTH=2
axis_downsizer/tb/axis_downsizer_tb.vhd
