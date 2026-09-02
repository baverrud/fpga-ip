# ============================================================================
# vhdl.f -- VHDL Design & Testbench File List
#
# Used by:
#   run pulse_extender vhdl modelsim     (simulation: [rtl] + [tb:default])
#   run pulse_extender vhdl vivado       (synthesis: [rtl] + [top] only)
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

[rtl]
pulse_extender/rtl/pulse_extender.vhd

[top]
pulse_extender/top/pulse_extender_top.vhd

[tb:default]
top = pulse_extender_tb
pulse_extender/tb/pulse_extender_tb.vhd
