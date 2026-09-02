//-----------------------------------------------------------------------
//Filename         : axi_mem_model_top.sv
//Description      : Synthesis wrapper for axi_mem_model (SystemVerilog).
//                 : Binds the VHDL core directly; passes the AXI
//                 : configuration and latency-timer widths through as
//                 : parameters and exposes the AR/R channels plus the
//                 : runtime latency/beat-gap controls.
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------

`timescale 1ns/1ps

module axi_mem_model_top #(
  parameter int unsigned GC_DATA_BYTES    = 64,  // bus width in bytes
  parameter int unsigned GC_ADDR_WIDTH    = 49,  // address width
  parameter int unsigned GC_ID_WIDTH      = 6,   // ID width
  parameter int unsigned GC_TIMER_WIDTH   = 16,  // latency/gap timer width
  parameter int unsigned GC_AR_FIFO_DEPTH = 8,   // AR-side latency FIFO depth
  parameter int unsigned GC_R_FIFO_DEPTH  = 8    // R-side beat-gap FIFO depth
) (
    // Clock and reset
    input logic aclk,     // clock
    input logic aresetn,  // active-low synchronous reset

    // Control
    input logic                      ar_base_enable,    // AR-side base delay enable
    input logic                      ar_jitter_enable,  // AR-side jitter enable
    input logic                      r_base_enable,     // R-side base delay enable
    input logic                      r_jitter_enable,   // R-side jitter enable
    input logic [GC_TIMER_WIDTH-1:0] base_latency,      // nominal first-beat delay
    input logic [GC_TIMER_WIDTH-1:0] base_beat_gap,     // nominal inter-beat gap

    // AXI4 AR channel
    input  logic [GC_ID_WIDTH-1:0]   ar_id,     // read address ID
    input  logic [GC_ADDR_WIDTH-1:0] ar_addr,   // read address
    input  logic [7:0]               ar_len,    // burst length (beats-1)
    input  logic                     ar_valid,  // address valid
    output logic                     ar_ready,  // address ready

    // AXI4 R channel
    output logic [GC_ID_WIDTH-1:0]     r_id,     // read response ID
    output logic [8*GC_DATA_BYTES-1:0] r_data,   // read data
    output logic [1:0]                 r_resp,   // read response (OKAY = 00)
    output logic                       r_last,   // last beat indicator
    output logic                       r_valid,  // read data valid
    input  logic                       r_ready   // read data ready
);

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
