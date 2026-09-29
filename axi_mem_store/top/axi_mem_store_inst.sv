//-----------------------------------------------------------------------
//Filename         : axi_mem_store_inst.sv
//Description      : SystemVerilog instantiation template for axi_mem_store.
//Author           : Rune Baeverrud
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------
`timescale 1ns/1ps

module axi_mem_store_inst #(
  parameter int unsigned GC_DATA_BYTES = 64,     // AXI data width in bytes
  parameter int unsigned GC_ADDR_WIDTH = 32,     // byte-address width
  parameter int unsigned GC_ID_WIDTH = 6,         // AXI ID width
  parameter int unsigned GC_TIMER_WIDTH = 16,     // latency timer width
  parameter int unsigned GC_AR_FIFO_DEPTH = 8,    // AR latency FIFO depth
  parameter int unsigned GC_R_FIFO_DEPTH = 8,     // R latency FIFO depth
  parameter int unsigned GC_MEM_SIZE_BYTES = 16384 // stored byte capacity
) ();
  // Replace these scratch signals with the surrounding design's connections.
  logic aclk, aresetn;
  // Runtime timing controls.
  logic ar_base_enable, ar_jitter_enable, r_base_enable, r_jitter_enable;
  logic [GC_TIMER_WIDTH-1:0] base_latency, base_beat_gap;
  // Byte population write interface and AXI read channels.
  logic [GC_ADDR_WIDTH-1:0] mem_wr_addr, ar_addr;
  logic [7:0] mem_wr_data, ar_len;
  logic mem_wr_valid, mem_wr_ready, mem_wr_error, ar_valid, ar_ready;
  logic [GC_ID_WIDTH-1:0] ar_id, r_id;
  logic [8*GC_DATA_BYTES-1:0] r_data;
  logic [1:0] r_resp;
  logic r_last, r_valid, r_ready;

  // Copy this instance into the surrounding hierarchy and connect its ports.
  axi_mem_store_top #(
    .GC_DATA_BYTES     (GC_DATA_BYTES),
    .GC_ADDR_WIDTH     (GC_ADDR_WIDTH),
    .GC_ID_WIDTH       (GC_ID_WIDTH),
    .GC_TIMER_WIDTH    (GC_TIMER_WIDTH),
    .GC_AR_FIFO_DEPTH  (GC_AR_FIFO_DEPTH),
    .GC_R_FIFO_DEPTH   (GC_R_FIFO_DEPTH),
    .GC_MEM_SIZE_BYTES (GC_MEM_SIZE_BYTES)
  ) u_axi_mem_store (
    .aclk (aclk), .aresetn (aresetn),
    .ar_base_enable (ar_base_enable), .ar_jitter_enable (ar_jitter_enable),
    .r_base_enable (r_base_enable), .r_jitter_enable (r_jitter_enable),
    .base_latency (base_latency), .base_beat_gap (base_beat_gap),
    .mem_wr_addr (mem_wr_addr), .mem_wr_data (mem_wr_data),
    .mem_wr_valid (mem_wr_valid), .mem_wr_ready (mem_wr_ready),
    .mem_wr_error (mem_wr_error),
    .ar_id (ar_id), .ar_addr (ar_addr), .ar_len (ar_len),
    .ar_valid (ar_valid), .ar_ready (ar_ready),
    .r_id (r_id), .r_data (r_data), .r_resp (r_resp),
    .r_last (r_last), .r_valid (r_valid), .r_ready (r_ready)
  );
endmodule
