//-----------------------------------------------------------------------
//Filename         : axi_read_bridge_top.sv
//Description      : SystemVerilog wrapper for axi_read_bridge_top.
//                 : The arrayed client req/rsp ports are packed with the
//                 : client index in the OUTER dimension; this wrapper
//                 : reverses the outer dimension so SV index j maps to
//                 : VHDL index j (same idiom as axi_ar_mux_top.sv).
//                 : All generics are passed through to the VHDL top via
//                 : mixed-language binding.
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------

`timescale 1ns/1ps

module axi_read_bridge_top #(
  parameter int unsigned GC_NUM_CLIENTS        = 4,
  parameter int unsigned GC_ADDR_WIDTH         = 32,
  parameter int unsigned GC_ID_WIDTH           = 4,
  parameter int unsigned GC_CLIENT_DATA_BYTES  = 64,
  parameter int unsigned GC_NATIVE_DATA_BYTES  = 16,
  parameter int unsigned GC_NATIVE_ARLEN_WIDTH = 8,
  parameter int unsigned GC_CLIENT_FIFO_DEPTH  = 32,
  parameter int unsigned GC_CDC_DEPTH          = 8,
  parameter int unsigned GC_SYNC_STAGES        = 2
) (
  // Clock / reset
  input logic aclk,
  input logic mem_aclk,
  input logic aresetn,   // synchronous, active low

  // Client request interfaces. req_len counts client-domain beats minus 1.
  input  logic [GC_NUM_CLIENTS-1:0][GC_ADDR_WIDTH-1:0]                                                               req_addr,
  input  logic [GC_NUM_CLIENTS-1:0][GC_NATIVE_ARLEN_WIDTH - $clog2(GC_CLIENT_DATA_BYTES / GC_NATIVE_DATA_BYTES)-1:0] req_len,
  input  logic [GC_NUM_CLIENTS-1:0]                                                                                  req_valid,
  output logic [GC_NUM_CLIENTS-1:0]                                                                                  req_ready,

  // Client response interfaces. One beat is GC_CLIENT_DATA_BYTES wide.
  output logic [GC_NUM_CLIENTS-1:0][8*GC_CLIENT_DATA_BYTES-1:0] rsp_data,
  output logic [GC_NUM_CLIENTS-1:0][1:0]                        rsp_resp,
  output logic [GC_NUM_CLIENTS-1:0]                             rsp_last,
  output logic [GC_NUM_CLIENTS-1:0]                             rsp_valid,
  input  logic [GC_NUM_CLIENTS-1:0]                             rsp_ready,

  // Native AXI read-address channel
  output logic [GC_ID_WIDTH-1:0]           ar_id,
  output logic [GC_ADDR_WIDTH-1:0]         ar_addr,
  output logic [GC_NATIVE_ARLEN_WIDTH-1:0] ar_len,
  output logic [2:0]                       ar_size,
  output logic                             ar_valid,
  input  logic                             ar_ready,

  // Native AXI read-data channel
  input  logic [GC_ID_WIDTH-1:0]            r_id,
  input  logic [8*GC_NATIVE_DATA_BYTES-1:0] r_data,
  input  logic [1:0]                        r_resp,
  input  logic                              r_last,
  input  logic                              r_valid,
  output logic                              r_ready
);

    localparam int unsigned C_CLIENT_ARLEN_WIDTH = GC_NATIVE_ARLEN_WIDTH -
        $clog2(GC_CLIENT_DATA_BYTES / GC_NATIVE_DATA_BYTES);

    // Reversed internal vectors feeding the VHDL top (SV index j -> VHDL index j).
    logic [GC_NUM_CLIENTS-1:0][GC_ADDR_WIDTH-1:0]          req_addr_v;
    logic [GC_NUM_CLIENTS-1:0][C_CLIENT_ARLEN_WIDTH-1:0]   req_len_v;
    logic [GC_NUM_CLIENTS-1:0]                             req_valid_v;
    logic [GC_NUM_CLIENTS-1:0]                             req_ready_v;
    logic [GC_NUM_CLIENTS-1:0][8*GC_CLIENT_DATA_BYTES-1:0] rsp_data_v;
    logic [GC_NUM_CLIENTS-1:0][1:0]                        rsp_resp_v;
    logic [GC_NUM_CLIENTS-1:0]                             rsp_last_v;
    logic [GC_NUM_CLIENTS-1:0]                             rsp_valid_v;
    logic [GC_NUM_CLIENTS-1:0]                             rsp_ready_v;

    genvar c;
    generate
        for (c = 0; c < GC_NUM_CLIENTS; c++) begin : g_reverse_clients
            assign req_addr_v[GC_NUM_CLIENTS-1-c]  = req_addr[c];
            assign req_len_v[GC_NUM_CLIENTS-1-c]   = req_len[c];
            assign req_valid_v[GC_NUM_CLIENTS-1-c] = req_valid[c];
            assign req_ready[c] = req_ready_v[GC_NUM_CLIENTS-1-c];
            assign rsp_data[c]  = rsp_data_v[GC_NUM_CLIENTS-1-c];
            assign rsp_resp[c]  = rsp_resp_v[GC_NUM_CLIENTS-1-c];
            assign rsp_last[c]  = rsp_last_v[GC_NUM_CLIENTS-1-c];
            assign rsp_valid[c] = rsp_valid_v[GC_NUM_CLIENTS-1-c];
            assign rsp_ready_v[GC_NUM_CLIENTS-1-c] = rsp_ready[c];
        end
    endgenerate

    // Instantiates the VHDL axi_read_bridge_top (mixed-language binding).
    axi_read_bridge_top #(
        .GC_NUM_CLIENTS        (GC_NUM_CLIENTS),
        .GC_ADDR_WIDTH         (GC_ADDR_WIDTH),
        .GC_ID_WIDTH           (GC_ID_WIDTH),
        .GC_CLIENT_DATA_BYTES  (GC_CLIENT_DATA_BYTES),
        .GC_NATIVE_DATA_BYTES  (GC_NATIVE_DATA_BYTES),
        .GC_NATIVE_ARLEN_WIDTH (GC_NATIVE_ARLEN_WIDTH),
        .GC_CLIENT_FIFO_DEPTH  (GC_CLIENT_FIFO_DEPTH),
        .GC_CDC_DEPTH          (GC_CDC_DEPTH),
        .GC_SYNC_STAGES        (GC_SYNC_STAGES)
    ) u_core (
        // Clock / reset
        .aclk     (aclk),
        .mem_aclk (mem_aclk),
        .aresetn  (aresetn),

        // Client request interfaces
        .req_addr  (req_addr_v),
        .req_len   (req_len_v),
        .req_valid (req_valid_v),
        .req_ready (req_ready_v),

        // Client response interfaces
        .rsp_data  (rsp_data_v),
        .rsp_resp  (rsp_resp_v),
        .rsp_last  (rsp_last_v),
        .rsp_valid (rsp_valid_v),
        .rsp_ready (rsp_ready_v),

        // Native AXI read-address channel
        .ar_id    (ar_id),
        .ar_addr  (ar_addr),
        .ar_len   (ar_len),
        .ar_size  (ar_size),
        .ar_valid (ar_valid),
        .ar_ready (ar_ready),

        // Native AXI read-data channel
        .r_id    (r_id),
        .r_data  (r_data),
        .r_resp  (r_resp),
        .r_last  (r_last),
        .r_valid (r_valid),
        .r_ready (r_ready)
    );

endmodule
