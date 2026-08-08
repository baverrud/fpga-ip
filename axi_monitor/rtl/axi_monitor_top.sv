//-----------------------------------------------------------------------
//Filename         : axi_monitor_top.sv
//Description      : Synthesis wrapper for axi_monitor (SystemVerilog).
//                 : Passes all AR/R channel taps and control/stat ports
//                 : through to the core (VHDL, mixed-language binding).
//                 : All AR/R signals are inputs -- the monitor is a
//                 : passive observer.
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------

`timescale 1ns/1ps

module axi_monitor_top #(
    parameter int unsigned GC_DATA_BYTES    = 64,
    parameter int unsigned GC_ADDR_WIDTH    = 49,
    parameter int unsigned GC_ID_WIDTH      = 6,
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

    // AR channel taps (inputs -- passive monitor)
    input logic                     ar_valid,
    input logic                     ar_ready,
    input logic [GC_ID_WIDTH-1:0]   ar_id,
    input logic [GC_ADDR_WIDTH-1:0] ar_addr,
    input logic [7:0]               ar_len,

    // R channel taps (inputs -- passive monitor)
    input logic                       r_valid,
    input logic                       r_ready,
    input logic [GC_ID_WIDTH-1:0]     r_id,
    input logic [8*GC_DATA_BYTES-1:0] r_data,
    input logic [1:0]                 r_resp,
    input logic                       r_last,

    // Statistics and status
    output logic [31:0]              stat_ar_seen,
    output logic [31:0]              stat_ar_stall,
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
    output logic [31:0]              stat_r_stall,
    output logic                     pipeline_busy,
    output logic [31:0]              stat_max_outstanding,
    output logic [31:0]              stat_data_errors,
    output logic [31:0]              stat_id_errors,
    output logic [31:0]              stat_rlast_errors,
    output logic [31:0]              stat_resp_errors,
    output logic [31:0]              stat_sb_underflow_errors
);

  axi_monitor #(
      .GC_DATA_BYTES    (GC_DATA_BYTES),
      .GC_ADDR_WIDTH    (GC_ADDR_WIDTH),
      .GC_ID_WIDTH      (GC_ID_WIDTH),
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

        // AR channel taps
      .ar_valid (ar_valid),
      .ar_ready (ar_ready),
      .ar_id    (ar_id),
      .ar_addr  (ar_addr),
      .ar_len   (ar_len),

        // R channel taps
      .r_valid (r_valid),
      .r_ready (r_ready),
      .r_id    (r_id),
      .r_data  (r_data),
      .r_resp  (r_resp),
      .r_last  (r_last),

        // Statistics and status
      .stat_ar_seen             (stat_ar_seen),
      .stat_ar_stall            (stat_ar_stall),
      .stat_sb_backpressure     (stat_sb_backpressure),
      .stat_xactions            (stat_xactions),
      .stat_beats               (stat_beats),
      .stat_latency_sum         (stat_latency_sum),
      .stat_latency_min         (stat_latency_min),
      .stat_latency_max         (stat_latency_max),
      .stat_first_latency_sum   (stat_first_latency_sum),
      .stat_first_latency_min   (stat_first_latency_min),
      .stat_first_latency_max   (stat_first_latency_max),
      .stat_interbeat_gap_sum   (stat_interbeat_gap_sum),
      .stat_interbeat_gap_min   (stat_interbeat_gap_min),
      .stat_interbeat_gap_max   (stat_interbeat_gap_max),
      .stat_burst_len_sum       (stat_burst_len_sum),
      .stat_burst_len_min       (stat_burst_len_min),
      .stat_burst_len_max       (stat_burst_len_max),
      .stat_elapsed_cycles      (stat_elapsed_cycles),
      .stat_r_stall             (stat_r_stall),
      .pipeline_busy            (pipeline_busy),
      .stat_max_outstanding     (stat_max_outstanding),
      .stat_data_errors         (stat_data_errors),
      .stat_id_errors           (stat_id_errors),
      .stat_rlast_errors        (stat_rlast_errors),
      .stat_resp_errors         (stat_resp_errors),
      .stat_sb_underflow_errors (stat_sb_underflow_errors)
  );

endmodule
