# ============================================================================
# vhdl.f -- axi_traffic_gen VHDL RTL & Testbench File List
#
# Used by:
#   run axi_traffic_gen vhdl modelsim       (simulation; default tb: reqgen)
#   run axi_traffic_gen vhdl modelsim --tb reqsimple   (hand-editable skeleton)
#   run axi_traffic_gen vhdl vivado         (synthesis: [rtl] + [top] only)
#   run axi_traffic_gen vhdl xsim           (XSim simulation)
#
# Section reference:
#   [rtl]        -- RTL sources always compiled
#   [top]        -- Synthesis top wrapper (vivado/xsim synthesis only)
#   [tb:<name>]  -- Testbench (simulation only, skipped in synthesis)
#
# Each line: <relative_path_from_sub_fpga_ip> [std=<vhdl_std>]
#   vhdl_std defaults to DEFAULT_STD (2008) if omitted.
# ============================================================================
DEFAULT_STD: 2008
DEFAULT_LIB: work
DEFAULT_TB: reqgen

[rtl]
common/rtl/util_pkg.vhd
parallel_prng/rtl/xorshift128.vhd
parallel_prng/rtl/xorshift32.vhd
axi_traffic_gen/rtl/axi_req_gen.vhd

[top]
axi_traffic_gen/rtl/axi_req_gen_top.vhd

[tb:reqgen]
top = axi_req_gen_tb
axis_fifo/rtl/axis_fifo.vhd
axi_ar_mux/rtl/axi_ar_mux.vhd
axis_cdc/rtl/axis_cdc.vhd
axis_upsizer/rtl/axis_upsizer.vhd
axi_r_demux/rtl/axi_r_demux.vhd
jitter_gen/rtl/jitter_gen.vhd
axis_latency_gen/rtl/axis_latency_gen.vhd
axi_mem_model/rtl/axi_mem_model_core.vhd
axi_mem_model/rtl/axi_mem_model.vhd
axi_read_bridge/rtl/axi_read_bridge.vhd
axi_monitor/rtl/axi_monitor_req.vhd
axi_monitor/rtl/axi_monitor_rsp.vhd
axi_monitor/rtl/axi_monitor.vhd
axi_traffic_gen/tb/axi_req_gen_tb.vhd

[tb:reqsimple]
top = axi_req_gen_simple_tb
axis_fifo/rtl/axis_fifo.vhd
axi_ar_mux/rtl/axi_ar_mux.vhd
axis_cdc/rtl/axis_cdc.vhd
axis_upsizer/rtl/axis_upsizer.vhd
axi_r_demux/rtl/axi_r_demux.vhd
jitter_gen/rtl/jitter_gen.vhd
axis_latency_gen/rtl/axis_latency_gen.vhd
axi_mem_model/rtl/axi_mem_model_core.vhd
axi_mem_model/rtl/axi_mem_model.vhd
axi_read_bridge/rtl/axi_read_bridge.vhd
axi_monitor/rtl/axi_monitor_req.vhd
axi_monitor/rtl/axi_monitor_rsp.vhd
axi_monitor/rtl/axi_monitor.vhd
axi_traffic_gen/tb/axi_req_gen_simple_tb.vhd
