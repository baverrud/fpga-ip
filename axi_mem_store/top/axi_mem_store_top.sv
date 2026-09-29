//-----------------------------------------------------------------------
//Filename         : axi_mem_store_top.sv
//Description      : SystemVerilog synthesis wrapper for axi_mem_store.
//Author           : Rune Baeverrud
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------
`timescale 1ns/1ps

module axi_mem_store_top #(
  parameter int unsigned GC_DATA_BYTES     = 64,    // AXI data width in bytes
  parameter int unsigned GC_ADDR_WIDTH     = 32,    // byte-address width
  parameter int unsigned GC_ID_WIDTH       = 6,     // AXI ID width
  parameter int unsigned GC_TIMER_WIDTH    = 16,    // latency timer width
  parameter int unsigned GC_AR_FIFO_DEPTH  = 8,     // AR latency FIFO depth
  parameter int unsigned GC_R_FIFO_DEPTH   = 8,     // R latency FIFO depth
  parameter int unsigned GC_MEM_SIZE_BYTES = 16384  // stored byte capacity
) (
  // Clock and synchronous active-low reset.
  input  logic aclk,
  input  logic aresetn,
  // Runtime request and response timing controls.
  input  logic ar_base_enable,
  input  logic ar_jitter_enable,
  input  logic r_base_enable,
  input  logic r_jitter_enable,
  input  logic [GC_TIMER_WIDTH-1:0] base_latency,
  input  logic [GC_TIMER_WIDTH-1:0] base_beat_gap,
  // One-byte memory population interface.
  input  logic [GC_ADDR_WIDTH-1:0] mem_wr_addr,
  input  logic [7:0] mem_wr_data,
  input  logic mem_wr_valid,
  output logic mem_wr_ready,
  output logic mem_wr_error,  // one-clock pulse on an invalid write
  // AXI4 read-address channel.
  input  logic [GC_ID_WIDTH-1:0] ar_id,
  input  logic [GC_ADDR_WIDTH-1:0] ar_addr,
  input  logic [7:0] ar_len,
  input  logic ar_valid,
  output logic ar_ready,
  // AXI4 read-data channel.
  output logic [GC_ID_WIDTH-1:0] r_id,
  output logic [8*GC_DATA_BYTES-1:0] r_data,
  output logic [1:0] r_resp,
  output logic r_last,
  output logic r_valid,
  input logic r_ready
);

  // Thin mixed-language wrapper. The VHDL entity contains the memory array,
  // AXI sequencer and both shared latency stages.
  axi_mem_store #(
    .GC_DATA_BYTES     (GC_DATA_BYTES),
    .GC_ADDR_WIDTH     (GC_ADDR_WIDTH),
    .GC_ID_WIDTH       (GC_ID_WIDTH),
    .GC_TIMER_WIDTH    (GC_TIMER_WIDTH),
    .GC_AR_FIFO_DEPTH  (GC_AR_FIFO_DEPTH),
    .GC_R_FIFO_DEPTH   (GC_R_FIFO_DEPTH),
    .GC_MEM_SIZE_BYTES (GC_MEM_SIZE_BYTES)
  ) u_axi_mem_store (
    .aclk              (aclk),
    .aresetn           (aresetn),
    .ar_base_enable    (ar_base_enable),
    .ar_jitter_enable  (ar_jitter_enable),
    .r_base_enable     (r_base_enable),
    .r_jitter_enable   (r_jitter_enable),
    .base_latency      (base_latency),
    .base_beat_gap     (base_beat_gap),
    .mem_wr_addr       (mem_wr_addr),
    .mem_wr_data       (mem_wr_data),
    .mem_wr_valid      (mem_wr_valid),
    .mem_wr_ready      (mem_wr_ready),
    .mem_wr_error      (mem_wr_error),
    .ar_id             (ar_id),
    .ar_addr           (ar_addr),
    .ar_len            (ar_len),
    .ar_valid          (ar_valid),
    .ar_ready          (ar_ready),
    .r_id              (r_id),
    .r_data            (r_data),
    .r_resp            (r_resp),
    .r_last            (r_last),
    .r_valid           (r_valid),
    .r_ready           (r_ready)
  );

endmodule
