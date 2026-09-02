//-----------------------------------------------------------------------
//Filename         : axi_monitor_top.sv
//Description      : Synthesis wrapper for axi_monitor (SystemVerilog).
//                 : Passes all req/rsp channel taps and control/stat
//                 : ports through to the core (VHDL, mixed-language
//                 : binding).  All req/rsp signals are inputs -- the
//                 : monitor is a passive observer.
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------

`timescale 1ns/1ps

module axi_monitor_top #(
  parameter int unsigned GC_DATA_BYTES    = 64,
  parameter int unsigned GC_ADDR_WIDTH    = 49,
  parameter int unsigned GC_TIME_WIDTH    = 48,
  parameter int unsigned GC_STAT_WIDTH    = 48,
  parameter int unsigned GC_SB_FIFO_DEPTH = 256
) (
  // Clock, reset, and timebase
  input logic                     aclk,         // clock
  input logic                     aresetn,      // active-low synchronous reset
  input logic [GC_TIME_WIDTH-1:0] global_time,

  // Control
  input logic enable,
  input logic stat_rst,
  input logic err_rst,
  input logic data_check_en,

  // req channel taps (inputs -- passive monitor)
  input logic                     req_valid,
  input logic                     req_ready,
  input logic [GC_ADDR_WIDTH-1:0] req_addr,
  input logic [7:0]               req_len,

  // rsp channel taps (inputs -- passive monitor)
  input logic                       rsp_valid,
  input logic                       rsp_ready,
  input logic [8*GC_DATA_BYTES-1:0] rsp_data,
  input logic [1:0]                 rsp_resp,
  input logic                       rsp_last,

  // Statistics and status
  output logic [31:0]              stat_req_seen,
  output logic [31:0]              stat_req_stall,
  output logic [31:0]              stat_sb_backpressure,
  output logic [31:0]              stat_xactions,
  output logic [31:0]              stat_beats,
  output logic [GC_STAT_WIDTH-1:0] stat_latency_sum,
  output logic [31:0]              stat_latency_min,
  output logic [31:0]              stat_latency_max,
  output logic [GC_STAT_WIDTH-1:0] stat_first_latency_sum,
  output logic [31:0]              stat_first_latency_min,
  output logic [31:0]              stat_first_latency_max,
  output logic [GC_STAT_WIDTH-1:0] stat_interbeat_gap_sum,
  output logic [31:0]              stat_interbeat_gap_min,
  output logic [31:0]              stat_interbeat_gap_max,
  output logic [GC_STAT_WIDTH-1:0] stat_burst_len_sum,
  output logic [31:0]              stat_burst_len_min,
  output logic [31:0]              stat_burst_len_max,
  output logic [31:0]              stat_elapsed_cycles,
  output logic [31:0]              stat_rsp_stall,
  output logic                     pipeline_busy,
  output logic [31:0]              stat_max_outstanding,
  output logic [31:0]              stat_data_errors,
  output logic [31:0]              stat_rlast_errors,
  output logic [31:0]              stat_resp_errors,
  output logic [31:0]              stat_sb_underflow_errors
);

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
