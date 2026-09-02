//-----------------------------------------------------------------------
//Filename         : axi_ar_mux_inst.sv
//Description      : Instantiation template for axi_ar_mux_top.
//                 : req_len counts client-domain beats minus 1; ARSIZE and
//                 : ARBURST are derived internally and the native ARLEN is
//                 : scaled by the configured client/native width ratio.
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------

`timescale 1ns/1ps
module axi_ar_mux_inst #(
  parameter int unsigned GC_NUM_CLIENTS        = 4,
  parameter int unsigned GC_ADDR_WIDTH         = 32,
  parameter int unsigned GC_ID_WIDTH           = 4,
  parameter int unsigned GC_CLIENT_DATA_WIDTH  = 512,
  parameter int unsigned GC_NATIVE_DATA_WIDTH  = 128,
  parameter int unsigned GC_CLIENT_ARLEN_WIDTH = 6,
  parameter int unsigned GC_NATIVE_ARLEN_WIDTH = 8,
  parameter int unsigned GC_FIFO_DEPTH         = 32,
  parameter int unsigned GC_R_BEATS_PER_POP    = 1,
  parameter logic [1:0]  GC_BURST_TYPE          = 2'b01
) ();
  logic aclk;
  logic aresetn;
  logic [GC_NUM_CLIENTS-1:0][GC_ADDR_WIDTH-1:0] req_addr;
  logic [GC_NUM_CLIENTS-1:0][GC_CLIENT_ARLEN_WIDTH-1:0] req_len;
  logic [GC_NUM_CLIENTS-1:0] req_valid;
  logic [GC_NUM_CLIENTS-1:0] req_ready;
  logic [GC_NUM_CLIENTS-1:0] r_pop;
  logic [GC_ID_WIDTH-1:0] ar_id;
  logic [GC_ADDR_WIDTH-1:0] ar_addr;
  logic [GC_NATIVE_ARLEN_WIDTH-1:0] ar_len;
  logic [2:0] ar_size;
  logic [1:0] ar_burst;
  logic ar_valid;
  logic ar_ready;


    localparam int unsigned C_RATIO = GC_CLIENT_DATA_WIDTH / GC_NATIVE_DATA_WIDTH;
    localparam logic [2:0] C_NATIVE_SIZE = $clog2(GC_NATIVE_DATA_WIDTH / 8);

    logic [GC_NUM_CLIENTS-1:0][GC_ADDR_WIDTH-1:0] req_addr_vhdl;
    logic [GC_NUM_CLIENTS-1:0][7:0]               req_len_vhdl;
    logic [GC_NUM_CLIENTS-1:0]                    req_valid_vhdl;
    logic [GC_NUM_CLIENTS-1:0]                    req_ready_vhdl;
    logic [GC_NUM_CLIENTS-1:0]                    r_pop_vhdl;
    logic [7:0]                                   core_ar_len;

    genvar client;
    generate
        for (client = 0; client < GC_NUM_CLIENTS; client++) begin : g_reverse_clients
            assign req_addr_vhdl[GC_NUM_CLIENTS-1-client] = req_addr[client];
            assign req_len_vhdl[GC_NUM_CLIENTS-1-client] =
              {{(8-GC_CLIENT_ARLEN_WIDTH){1'b0}}, req_len[client]};
            assign req_valid_vhdl[GC_NUM_CLIENTS-1-client] = req_valid[client];
            assign req_ready[client] = req_ready_vhdl[GC_NUM_CLIENTS-1-client];
            assign r_pop_vhdl[GC_NUM_CLIENTS-1-client] = r_pop[client];
        end
    endgenerate

    axi_ar_mux #(
    .GC_NUM_CLIENTS     (GC_NUM_CLIENTS),
    .GC_ADDR_WIDTH      (GC_ADDR_WIDTH),
    .GC_ID_WIDTH        (GC_ID_WIDTH),
    .GC_FIFO_DEPTH      (GC_FIFO_DEPTH),
    .GC_R_BEATS_PER_POP (GC_R_BEATS_PER_POP)
  ) u_core (
    .aclk      (aclk),
    .aresetn   (aresetn),
    .req_addr  (req_addr_vhdl),
    .req_len   (req_len_vhdl),
    .req_valid (req_valid_vhdl),
    .req_ready (req_ready_vhdl),
    .r_pop     (r_pop_vhdl),
    .ar_id     (ar_id),
    .ar_addr   (ar_addr),
    .ar_len    (core_ar_len),
    .ar_valid  (ar_valid),
    .ar_ready  (ar_ready)
  );

    assign ar_len = ((core_ar_len + 8'd1) * C_RATIO) - 1;
    assign ar_size = C_NATIVE_SIZE;
    assign ar_burst = GC_BURST_TYPE;

endmodule
