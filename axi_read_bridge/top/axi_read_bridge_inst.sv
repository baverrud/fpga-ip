//-----------------------------------------------------------------------
//Filename         : axi_read_bridge_inst.sv
//Description      : Instantiation template for axi_read_bridge.
//                 : Declares internal signals and instantiates the VHDL
//                 : core directly through mixed-language binding.
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------

`timescale 1ns/1ps
module axi_read_bridge_inst #(
  parameter int unsigned GC_NUM_CLIENTS        = 4,
  parameter int unsigned GC_ADDR_WIDTH         = 32,
  parameter int unsigned GC_ID_WIDTH           = 4,
  parameter int unsigned GC_CLIENT_DATA_BYTES  = 64,
  parameter int unsigned GC_NATIVE_DATA_BYTES  = 16,
  parameter int unsigned GC_NATIVE_ARLEN_WIDTH = 8,
  parameter int unsigned GC_CLIENT_FIFO_DEPTH  = 32,
  parameter int unsigned GC_CDC_DEPTH          = 8,
  parameter int unsigned GC_SYNC_STAGES        = 2
) ();
  logic aclk;
  logic mem_aclk;
  logic aresetn;
  logic [GC_NUM_CLIENTS-1:0][GC_ADDR_WIDTH-1:0] req_addr;
  logic [GC_NUM_CLIENTS-1:0][GC_NATIVE_ARLEN_WIDTH - $clog2(GC_CLIENT_DATA_BYTES / GC_NATIVE_DATA_BYTES)-1:0] req_len;
  logic [GC_NUM_CLIENTS-1:0] req_valid;
  logic [GC_NUM_CLIENTS-1:0] req_ready;
  logic [GC_NUM_CLIENTS-1:0][8*GC_CLIENT_DATA_BYTES-1:0] rsp_data;
  logic [GC_NUM_CLIENTS-1:0][1:0] rsp_resp;
  logic [GC_NUM_CLIENTS-1:0] rsp_last;
  logic [GC_NUM_CLIENTS-1:0] rsp_valid;
  logic [GC_NUM_CLIENTS-1:0] rsp_ready;
  logic [GC_ID_WIDTH-1:0] ar_id;
  logic [GC_ADDR_WIDTH-1:0] ar_addr;
  logic [GC_NATIVE_ARLEN_WIDTH-1:0] ar_len;
  logic ar_valid;
  logic ar_ready;
  logic [GC_ID_WIDTH-1:0] r_id;
  logic [8*GC_NATIVE_DATA_BYTES-1:0] r_data;
  logic [1:0] r_resp;
  logic r_last;
  logic r_valid;
  logic r_ready;

  axi_read_bridge #(
    .GC_NUM_CLIENTS        (GC_NUM_CLIENTS),
    .GC_ADDR_WIDTH         (GC_ADDR_WIDTH),
    .GC_ID_WIDTH           (GC_ID_WIDTH),
    .GC_CLIENT_DATA_BYTES  (GC_CLIENT_DATA_BYTES),
    .GC_NATIVE_DATA_BYTES  (GC_NATIVE_DATA_BYTES),
    .GC_NATIVE_ARLEN_WIDTH (GC_NATIVE_ARLEN_WIDTH),
    .GC_CLIENT_FIFO_DEPTH  (GC_CLIENT_FIFO_DEPTH),
    .GC_CDC_DEPTH          (GC_CDC_DEPTH),
    .GC_SYNC_STAGES        (GC_SYNC_STAGES)
  ) u_axi_read_bridge (
    .aclk       (aclk),
    .mem_aclk   (mem_aclk),
    .aresetn    (aresetn),
    .req_addr   (req_addr),
    .req_len    (req_len),
    .req_valid  (req_valid),
    .req_ready  (req_ready),
    .rsp_data   (rsp_data),
    .rsp_resp   (rsp_resp),
    .rsp_last   (rsp_last),
    .rsp_valid  (rsp_valid),
    .rsp_ready  (rsp_ready),
    .ar_id      (ar_id),
    .ar_addr    (ar_addr),
    .ar_len     (ar_len),
    .ar_valid   (ar_valid),
    .ar_ready   (ar_ready),
    .r_id       (r_id),
    .r_data     (r_data),
    .r_resp     (r_resp),
    .r_last     (r_last),
    .r_valid    (r_valid),
    .r_ready    (r_ready)
  );

endmodule
