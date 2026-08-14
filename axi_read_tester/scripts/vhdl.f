# ============================================================================
# vhdl.f -- axi_read_tester VHDL RTL & Testbench File List
#
# Used by:
#   run axi_read_tester vhdl modelsim   (simulation; default tb: default)
#   run axi_read_tester vhdl vivado     (synthesis: [rtl] + [top] only)
#   run axi_read_tester vhdl xsim       (XSim simulation)
#
# Section reference:
#   [rtl]        -- RTL sources always compiled (dependencies first)
#   [top]        -- Synthesis top wrapper (synthesis only, not used in sim)
#   [tb:<name>]  -- Testbench (simulation only, skipped in synthesis)
#
# Each line: <relative_path_from_sub_fpga_ip> [std=<vhdl_std>]
#   vhdl_std defaults to DEFAULT_STD (2008) if omitted.
#
# The closure lists every dependency inline (repo convention): util_pkg,
# the bridge core and its sub-IPs, the monitor (req/rsp/core), the request
# generator and its PRNGs, and the AXI4-Lite register bridge. axi_mem_model
# is only needed by the testbench (the core exposes the native AXI master).
# ============================================================================
DEFAULT_STD: 2008
DEFAULT_LIB: work
DEFAULT_TB: default

[rtl]
common/rtl/util_pkg.vhd
axis_fifo/rtl/axis_fifo.vhd
axi_ar_mux/rtl/axi_ar_mux.vhd
axis_cdc/rtl/axis_cdc.vhd
axis_upsizer/rtl/axis_upsizer.vhd
axi_r_demux/rtl/axi_r_demux.vhd
parallel_prng/rtl/xorshift32.vhd
parallel_prng/rtl/xorshift128.vhd
jitter_gen/rtl/jitter_gen.vhd
axis_latency_gen/rtl/axis_latency_gen.vhd
pulse_extender/rtl/pulse_extender.vhd
common/rtl/axis_bfm_pkg.vhd
axi_monitor/rtl/axi_monitor_req.vhd
axi_monitor/rtl/axi_monitor_rsp.vhd
axi_monitor/rtl/axi_monitor.vhd
axi_traffic_gen/rtl/axi_req_gen.vhd
axilite_io/rtl/axilite_io.vhd
axi_read_bridge/rtl/axi_read_bridge.vhd
axi_read_tester/rtl/axi_read_tester.vhd

[top]
axi_read_tester/rtl/axi_read_tester_top.vhd

[constraints:vivado]
axi_read_tester/constraints/axi_read_tester.xdc

[tb:default]
top = axi_read_tester_tb
axi_mem_model/rtl/axi_mem_model_core.vhd
axi_mem_model/rtl/axi_mem_model.vhd
axi_read_tester/tb/axi_read_tester_tb.vhd
