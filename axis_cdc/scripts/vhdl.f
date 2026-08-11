# ============================================================================
# vhdl.f -- VHDL Design & Testbench File List
#
# Used by:
#   run axis_cdc vhdl modelsim         (simulation: [rtl] + [tb:default])
#   run axis_cdc vhdl modelsim --tb rev    (simulation: [rtl] + [tb:rev],
#                                           destination-faster direction)
#   run axis_cdc vhdl modelsim --tb wide   (simulation: [rtl] + [tb:wide],
#                                           512-bit payload)
#   run axis_cdc vhdl vivado           (synthesis: [rtl] + [top] only)
#
# Section reference:
#   [rtl]        -- RTL sources always compiled
#   [top]        -- Top wrapper (synthesis only, not used in sim)
#   [tb:<name>]  -- Testbench (simulation only, skipped in synthesis)
#   [constraints:<tool>] -- Tool-specific constraints (e.g. Vivado XDC),
#                          synthesis only, added to constrs_1
#
# Testbench metadata:
#   top      = <entity>        top-level testbench entity
#   generics = <name=value>,..  top-level generic overrides (vsim -g /
#                               xelab -generic_top); values must not
#                               contain spaces (e.g. 13ns, not 13 ns)
#
# Each line: <relative_path_from_sub_fpga_ip> [std=<vhdl_std>]
#   vhdl_std defaults to DEFAULT_STD (2008) if omitted.
# ============================================================================
DEFAULT_STD : 2008
DEFAULT_LIB : work
DEFAULT_TB  : default

[rtl]
common/rtl/util_pkg.vhd
axis_cdc/rtl/axis_cdc.vhd

[top]
axis_cdc/rtl/axis_cdc_top.vhd

[tb:default]
top = axis_cdc_tb
axis_cdc/tb/axis_cdc_tb.vhd

[tb:rev]
top = axis_cdc_tb
generics = GC_TS=13ns, GC_TM=10ns
axis_cdc/tb/axis_cdc_tb.vhd

[tb:wide]
top = axis_cdc_tb
generics = GC_TDATA_WIDTH=512
axis_cdc/tb/axis_cdc_tb.vhd
