# ============================================================================
# vhdl.f -- VHDL Design & Testbench File List
#
# Used by:
#   run axis_upsizer vhdl modelsim     (simulation: [rtl] + [tb:<name>])
#   run axis_upsizer vhdl vivado       (synthesis: [rtl] + [top] only)
#   run axis_upsizer vhdl xsim         (XSim simulation)
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
axis_upsizer/rtl/axis_upsizer.vhd

[top]
axis_upsizer/top/axis_upsizer_top.vhd

[tb:default]
top = axis_upsizer_tb
axis_upsizer/tb/axis_upsizer_tb.vhd

[tb:narrow]
top = axis_upsizer_tb
generics = GC_S_WIDTH=8, GC_RATIO=4, GC_ID_WIDTH=4
axis_upsizer/tb/axis_upsizer_tb.vhd

[tb:x2]
top = axis_upsizer_tb
generics = GC_RATIO=2, GC_ID_WIDTH=4
axis_upsizer/tb/axis_upsizer_tb.vhd

[tb:pass]
top = axis_upsizer_tb
generics = GC_RATIO=1, GC_ID_WIDTH=1
axis_upsizer/tb/axis_upsizer_tb.vhd

[tb:x3]
top = axis_upsizer_tb
generics = GC_RATIO=3, GC_ID_WIDTH=3
axis_upsizer/tb/axis_upsizer_tb.vhd

[tb:x8]
top = axis_upsizer_tb
generics = GC_RATIO=8, GC_ID_WIDTH=6
axis_upsizer/tb/axis_upsizer_tb.vhd

[tb:small]
top = axis_upsizer_tb
generics = GC_S_WIDTH=4, GC_RATIO=2, GC_ID_WIDTH=2
axis_upsizer/tb/axis_upsizer_tb.vhd
