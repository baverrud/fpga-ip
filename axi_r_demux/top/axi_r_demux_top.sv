//-----------------------------------------------------------------------
//Filename         : axi_r_demux_top.sv
//Description      : Synthesis wrapper for axi_r_demux (SystemVerilog),
//                 : defaulted to the 4-client, 32-bit, 4-bit-ID, depth-32
//                 : configuration. Array ports are exposed as packed
//                 : arrays (client index in the outer dimension).
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------

`timescale 1ns/1ps

module axi_r_demux_top #(
    parameter int unsigned GC_NUM_CLIENTS = 4,  // number of clients
    parameter int unsigned GC_DATA_BYTES  = 4,  // data width in bytes
    parameter int unsigned GC_ID_WIDTH    = 4,  // R ID width
    parameter int unsigned GC_FIFO_DEPTH  = 32  // per-client FIFO depth
) (
    // Clock / reset
    input logic aclk,
    input logic aresetn,

    // AXI Read Data Channel
    input  logic [GC_ID_WIDTH-1:0]     r_id,
    input  logic [8*GC_DATA_BYTES-1:0] r_data,
    input  logic [1:0]                 r_resp,
    input  logic                       r_last,
    input  logic                       r_valid,
    output logic                       r_ready,

    // Demuxed client response interfaces
    output logic [GC_NUM_CLIENTS-1:0][8*GC_DATA_BYTES-1:0] rsp_data,
    output logic [GC_NUM_CLIENTS-1:0][1:0]                 rsp_resp,
    output logic [GC_NUM_CLIENTS-1:0]                      rsp_last,
    output logic [GC_NUM_CLIENTS-1:0]                      rsp_valid,
    input  logic [GC_NUM_CLIENTS-1:0]                      rsp_ready,

    // Credit return pulses
    output logic [GC_NUM_CLIENTS-1:0] r_pop
);

  axi_r_demux #(
      .GC_NUM_CLIENTS (GC_NUM_CLIENTS),
      .GC_DATA_BYTES  (GC_DATA_BYTES),
      .GC_ID_WIDTH    (GC_ID_WIDTH),
      .GC_FIFO_DEPTH  (GC_FIFO_DEPTH)
  ) u_core (
      .aclk      (aclk),
      .aresetn   (aresetn),
      .r_id      (r_id),
      .r_data    (r_data),
      .r_resp    (r_resp),
      .r_last    (r_last),
      .r_valid   (r_valid),
      .r_ready   (r_ready),
      .rsp_data  (rsp_data),
      .rsp_resp  (rsp_resp),
      .rsp_last  (rsp_last),
      .rsp_valid (rsp_valid),
      .rsp_ready (rsp_ready),
      .r_pop     (r_pop)
  );

endmodule
