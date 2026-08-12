# ============================================================================
# vhdl.f -- axi_monitor VHDL RTL & Testbench File List
#
# Used by:
#   run axi_monitor vhdl modelsim       (simulation; default tb: monitor)
#   run axi_monitor vhdl vivado         (synthesis: [rtl] + [top] only)
#   run axi_monitor vhdl xsim           (XSim simulation)
#
# Section reference:
#   [rtl]        -- RTL sources always compiled
#   [top]        -- Top wrapper (synthesis only, not used in sim)
#   [tb:<name>]  -- Testbench (simulation only, skipped in synthesis)
#
# Each line: <relative_path_from_sub_fpga_ip> [std=<vhdl_std>]
#   vhdl_std defaults to DEFAULT_STD (2008) if omitted.
#
# The monitor's own RTL needs only util_pkg + axis_fifo (scoreboard).
# The [tb:monitor] section adds axi_read_bridge + axi_mem_model so the
# integration testbench can tap a real bridge client interface.
# ============================================================================
DEFAULT_STD: 2008
DEFAULT_LIB: work
DEFAULT_TB: monitor

[rtl]
common/rtl/util_pkg.vhd
common/rtl/axis_bfm_pkg.vhd
axis_fifo/rtl/axis_fifo.vhd
axi_monitor/rtl/axi_monitor_req.vhd
axi_monitor/rtl/axi_monitor_rsp.vhd
axi_monitor/rtl/axi_monitor.vhd

[top]
axi_monitor/rtl/axi_monitor_top.vhd

[tb:monitor]
top = axi_monitor_tb
axi_ar_mux/rtl/axi_ar_mux.vhd
axis_cdc/rtl/axis_cdc.vhd
axis_upsizer/rtl/axis_upsizer.vhd
axi_r_demux/rtl/axi_r_demux.vhd
parallel_prng/rtl/xorshift32.vhd
parallel_prng/rtl/xorshift128.vhd
jitter_gen/rtl/jitter_gen.vhd
axis_latency_gen/rtl/axis_latency_gen.vhd
axi_mem_model/rtl/axi_mem_model_core.vhd
axi_mem_model/rtl/axi_mem_model.vhd
axi_read_bridge/rtl/axi_read_bridge.vhd
axi_monitor/tb/axi_monitor_tb.vhd

[tb:simple]
top = axi_monitor_simple_tb
axi_monitor/tb/axi_monitor_simple_tb.vhd
