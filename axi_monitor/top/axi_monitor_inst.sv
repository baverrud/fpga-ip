//-----------------------------------------------------------------------
//Filename         : axi_monitor_inst.sv
//Description      : Instantiation template for axi_monitor_top.
//                 : Passes all req/rsp channel taps and control/stat
//                 : ports through to the core (VHDL, mixed-language
//                 : binding).  All req/rsp signals are inputs -- the
//                 : monitor is a passive observer.
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------

`timescale 1ns/1ps
module axi_monitor_inst #(
    parameter int unsigned GC_DATA_BYTES    = 64,
    parameter int unsigned GC_ADDR_WIDTH    = 49,
    parameter int unsigned GC_TIME_WIDTH    = 48,
    parameter int unsigned GC_STAT_WIDTH    = 48,
    parameter int unsigned GC_SB_FIFO_DEPTH = 256
) ();
  logic aclk;
  logic aresetn;
  logic [GC_TIME_WIDTH-1:0] global_time;
  logic enable;
  logic stat_rst;
  logic err_rst;
  logic data_check_en;
  logic req_valid;
  logic req_ready;
  logic [GC_ADDR_WIDTH-1:0] req_addr;
  logic [7:0] req_len;
  logic rsp_valid;
  logic rsp_ready;
  logic [8*GC_DATA_BYTES-1:0] rsp_data;
  logic [1:0] rsp_resp;
  logic rsp_last;
  logic [31:0] stat_req_seen;
  logic [31:0] stat_req_stall;
  logic [31:0] stat_sb_backpressure;
  logic [31:0] stat_xactions;
  logic [31:0] stat_beats;
  logic [GC_STAT_WIDTH-1:0] stat_latency_sum;
  logic [31:0] stat_latency_min;
  logic [31:0] stat_latency_max;
  logic [GC_STAT_WIDTH-1:0] stat_first_latency_sum;
  logic [31:0] stat_first_latency_min;
  logic [31:0] stat_first_latency_max;
  logic [GC_STAT_WIDTH-1:0] stat_interbeat_gap_sum;
  logic [31:0] stat_interbeat_gap_min;
  logic [31:0] stat_interbeat_gap_max;
  logic [GC_STAT_WIDTH-1:0] stat_burst_len_sum;
  logic [31:0] stat_burst_len_min;
  logic [31:0] stat_burst_len_max;
  logic [31:0] stat_elapsed_cycles;
  logic [31:0] stat_rsp_stall;
  logic pipeline_busy;
  logic [31:0] stat_max_outstanding;
  logic [31:0] stat_data_errors;
  logic [31:0] stat_rlast_errors;
  logic [31:0] stat_resp_errors;
  logic [31:0] stat_sb_underflow_errors;


  axi_monitor #(
      .GC_DATA_BYTES    (GC_DATA_BYTES),
      .GC_ADDR_WIDTH    (GC_ADDR_WIDTH),
      .GC_TIME_WIDTH    (GC_TIME_WIDTH),
      .GC_STAT_WIDTH    (GC_STAT_WIDTH),
      .GC_SB_FIFO_DEPTH (GC_SB_FIFO_DEPTH)
  ) u_axi_monitor (
      // Clock, reset, and timebase
      .aclk        (aclk),
      .aresetn     (aresetn),
      .global_time (global_time),

      // Control
      .enable        (enable),
      .stat_rst      (stat_rst),
      .err_rst       (err_rst),
      .data_check_en (data_check_en),

      // req channel taps
      .req_valid (req_valid),
      .req_ready (req_ready),
      .req_addr  (req_addr),
      .req_len   (req_len),

      // rsp channel taps
      .rsp_valid (rsp_valid),
      .rsp_ready (rsp_ready),
      .rsp_data  (rsp_data),
      .rsp_resp  (rsp_resp),
      .rsp_last  (rsp_last),

      // Statistics and status
      .stat_req_seen             (stat_req_seen),
      .stat_req_stall            (stat_req_stall),
      .stat_sb_backpressure      (stat_sb_backpressure),
      .stat_xactions             (stat_xactions),
      .stat_beats                (stat_beats),
      .stat_latency_sum          (stat_latency_sum),
      .stat_latency_min          (stat_latency_min),
      .stat_latency_max          (stat_latency_max),
      .stat_first_latency_sum    (stat_first_latency_sum),
      .stat_first_latency_min    (stat_first_latency_min),
      .stat_first_latency_max    (stat_first_latency_max),
      .stat_interbeat_gap_sum    (stat_interbeat_gap_sum),
      .stat_interbeat_gap_min    (stat_interbeat_gap_min),
      .stat_interbeat_gap_max    (stat_interbeat_gap_max),
      .stat_burst_len_sum        (stat_burst_len_sum),
      .stat_burst_len_min        (stat_burst_len_min),
      .stat_burst_len_max        (stat_burst_len_max),
      .stat_elapsed_cycles       (stat_elapsed_cycles),
      .stat_rsp_stall            (stat_rsp_stall),
      .pipeline_busy             (pipeline_busy),
      .stat_max_outstanding      (stat_max_outstanding),
      .stat_data_errors          (stat_data_errors),
      .stat_rlast_errors         (stat_rlast_errors),
      .stat_resp_errors          (stat_resp_errors),
      .stat_sb_underflow_errors  (stat_sb_underflow_errors)
  );

endmodule
