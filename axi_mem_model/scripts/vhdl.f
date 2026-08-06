# ============================================================================
# vhdl.f -- VHDL Design & Testbench File List
#
# Used by:
#   run axi_mem_model vhdl modelsim     (simulation: [rtl] + [tb:default])
#   run axi_mem_model vhdl vivado       (synthesis: [rtl] + [top] only)
#
# Section reference:
#   [rtl]        -- RTL sources always compiled (simulation + synthesis)
#   [top]        -- Synthesis top: either a wrapper file (synthesis only, not
#                   used in sim) or the metadata line 'top = <entity>' when
#                   the top is a regular [rtl] source
#   [tb:<name>]  -- Testbench (simulation only, skipped in synthesis)
#
# Each line: <relative_path_from_sub_fpga_ip> [std=<vhdl_std>]
#   vhdl_std defaults to DEFAULT_STD (2008) if omitted.
# ============================================================================
DEFAULT_STD: 2008
DEFAULT_LIB: work

[rtl]
common/rtl/util_pkg.vhd
axis_fifo/rtl/axis_fifo.vhd
parallel_prng/rtl/xorshift32.vhd
parallel_prng/rtl/xorshift128.vhd
jitter_gen/rtl/jitter_gen.vhd
axis_latency_gen/rtl/axis_latency_gen.vhd
axi_mem_model/rtl/axi_mem_model_core.vhd
axi_mem_model/rtl/axi_mem_model.vhd

[top]
top = axi_mem_model

[tb:default]
top = axi_mem_model_tb
axi_mem_model/tb/axi_mem_model_tb.vhd
