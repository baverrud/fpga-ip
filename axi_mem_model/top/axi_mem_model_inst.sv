//-----------------------------------------------------------------------
//Filename         : axi_mem_model_inst.sv
//Description      : Instantiation template for axi_mem_model_top.
//                 : Binds the VHDL core directly; passes the AXI
//                 : configuration and latency-timer widths through as
//                 : parameters and exposes the AR/R channels plus the
//                 : runtime latency/beat-gap controls.
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------

`timescale 1ns/1ps
module axi_mem_model_inst #(
  parameter int unsigned GC_DATA_BYTES    = 64,  // bus width in bytes
  parameter int unsigned GC_ADDR_WIDTH    = 49,  // address width
  parameter int unsigned GC_ID_WIDTH      = 6,   // ID width
  parameter int unsigned GC_TIMER_WIDTH   = 16,  // latency/gap timer width
  parameter int unsigned GC_AR_FIFO_DEPTH = 8,   // AR-side latency FIFO depth
  parameter int unsigned GC_R_FIFO_DEPTH  = 8    // R-side beat-gap FIFO depth
) ();
  logic aclk;
  logic aresetn;
  logic ar_base_enable;
  logic ar_jitter_enable;
  logic r_base_enable;
  logic r_jitter_enable;
  logic [GC_TIMER_WIDTH-1:0] base_latency;
  logic [GC_TIMER_WIDTH-1:0] base_beat_gap;
  logic [GC_ID_WIDTH-1:0] ar_id;
  logic [GC_ADDR_WIDTH-1:0] ar_addr;
  logic [7:0] ar_len;
  logic ar_valid;
  logic ar_ready;
  logic [GC_ID_WIDTH-1:0] r_id;
  logic [8*GC_DATA_BYTES-1:0] r_data;
  logic [1:0] r_resp;
  logic r_last;
  logic r_valid;
  logic r_ready;


  axi_mem_model #(
    .GC_DATA_BYTES    (GC_DATA_BYTES),
    .GC_ADDR_WIDTH    (GC_ADDR_WIDTH),
    .GC_ID_WIDTH      (GC_ID_WIDTH),
    .GC_TIMER_WIDTH   (GC_TIMER_WIDTH),
    .GC_AR_FIFO_DEPTH (GC_AR_FIFO_DEPTH),
    .GC_R_FIFO_DEPTH  (GC_R_FIFO_DEPTH)
  ) u_axi_mem_model (
  // Clock and reset
    .aclk    (aclk),
    .aresetn (aresetn),

  // Control
    .ar_base_enable   (ar_base_enable),
    .ar_jitter_enable (ar_jitter_enable),
    .r_base_enable    (r_base_enable),
    .r_jitter_enable  (r_jitter_enable),
    .base_latency     (base_latency),
    .base_beat_gap    (base_beat_gap),

  // AXI4 AR channel
    .ar_id    (ar_id),
    .ar_addr  (ar_addr),
    .ar_len   (ar_len),
    .ar_valid (ar_valid),
    .ar_ready (ar_ready),

  // AXI4 R channel
    .r_id    (r_id),
    .r_data  (r_data),
    .r_resp  (r_resp),
    .r_last  (r_last),
    .r_valid (r_valid),
    .r_ready (r_ready)
  );

endmodule
