//-----------------------------------------------------------------------
//Filename         : axi_read_tester_inst.sv
//Description      : Instantiation template for axi_read_tester.
//                 : Declares internal signals and instantiates the VHDL
//                 : core directly through mixed-language binding.
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------

`timescale 1ns/1ps
module axi_read_tester_inst #(
  parameter int unsigned GC_NUM_CLIENTS        = 4,
  parameter int unsigned GC_ADDR_WIDTH         = 32,
  parameter int unsigned GC_ID_WIDTH           = 4,
  parameter int unsigned GC_CLIENT_DATA_BYTES  = 64,
  parameter int unsigned GC_NATIVE_DATA_BYTES  = 16,
  parameter int unsigned GC_NATIVE_ARLEN_WIDTH = 8,
  parameter int unsigned GC_MAX_BURST          = 32,
  parameter int unsigned GC_CLIENT_FIFO_DEPTH  = 32,
  parameter int unsigned GC_CDC_DEPTH          = 8,
  parameter int unsigned GC_SYNC_STAGES        = 2,
  parameter int unsigned GC_MON_SB_DEPTH       = 32,
  parameter int unsigned GC_MON_TIME_WIDTH     = 48
) ();
  logic aclk;
  logic mem_aclk;
  logic aresetn;
  logic [GC_NUM_CLIENTS-1:0][15:0] s_axi_awaddr;
  logic [GC_NUM_CLIENTS-1:0][2:0] s_axi_awprot;
  logic [GC_NUM_CLIENTS-1:0] s_axi_awvalid;
  logic [GC_NUM_CLIENTS-1:0] s_axi_awready;
  logic [GC_NUM_CLIENTS-1:0][31:0] s_axi_wdata;
  logic [GC_NUM_CLIENTS-1:0][3:0] s_axi_wstrb;
  logic [GC_NUM_CLIENTS-1:0] s_axi_wvalid;
  logic [GC_NUM_CLIENTS-1:0] s_axi_wready;
  logic [GC_NUM_CLIENTS-1:0][1:0] s_axi_bresp;
  logic [GC_NUM_CLIENTS-1:0] s_axi_bvalid;
  logic [GC_NUM_CLIENTS-1:0] s_axi_bready;
  logic [GC_NUM_CLIENTS-1:0][15:0] s_axi_araddr;
  logic [GC_NUM_CLIENTS-1:0][2:0] s_axi_arprot;
  logic [GC_NUM_CLIENTS-1:0] s_axi_arvalid;
  logic [GC_NUM_CLIENTS-1:0] s_axi_arready;
  logic [GC_NUM_CLIENTS-1:0][31:0] s_axi_rdata;
  logic [GC_NUM_CLIENTS-1:0][1:0] s_axi_rresp;
  logic [GC_NUM_CLIENTS-1:0] s_axi_rvalid;
  logic [GC_NUM_CLIENTS-1:0] s_axi_rready;
  logic [GC_NUM_CLIENTS-1:0] pipeline_busy;
  logic [GC_NUM_CLIENTS-1:0] led;
  logic aperture;
  logic stat_rst;
  logic err_rst;
  logic [GC_MON_TIME_WIDTH-1:0] global_time;
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

  axi_read_tester #(
    .GC_NUM_CLIENTS        (GC_NUM_CLIENTS),
    .GC_ADDR_WIDTH         (GC_ADDR_WIDTH),
    .GC_ID_WIDTH           (GC_ID_WIDTH),
    .GC_CLIENT_DATA_BYTES  (GC_CLIENT_DATA_BYTES),
    .GC_NATIVE_DATA_BYTES  (GC_NATIVE_DATA_BYTES),
    .GC_NATIVE_ARLEN_WIDTH (GC_NATIVE_ARLEN_WIDTH),
    .GC_MAX_BURST          (GC_MAX_BURST),
    .GC_CLIENT_FIFO_DEPTH  (GC_CLIENT_FIFO_DEPTH),
    .GC_CDC_DEPTH          (GC_CDC_DEPTH),
    .GC_SYNC_STAGES        (GC_SYNC_STAGES),
    .GC_MON_SB_DEPTH       (GC_MON_SB_DEPTH),
    .GC_MON_TIME_WIDTH     (GC_MON_TIME_WIDTH)
  ) u_axi_read_tester (
    .aclk          (aclk),
    .mem_aclk      (mem_aclk),
    .aresetn       (aresetn),
    .s_axi_awaddr  (s_axi_awaddr),
    .s_axi_awprot  (s_axi_awprot),
    .s_axi_awvalid (s_axi_awvalid),
    .s_axi_awready (s_axi_awready),
    .s_axi_wdata   (s_axi_wdata),
    .s_axi_wstrb   (s_axi_wstrb),
    .s_axi_wvalid  (s_axi_wvalid),
    .s_axi_wready  (s_axi_wready),
    .s_axi_bresp   (s_axi_bresp),
    .s_axi_bvalid  (s_axi_bvalid),
    .s_axi_bready  (s_axi_bready),
    .s_axi_araddr  (s_axi_araddr),
    .s_axi_arprot  (s_axi_arprot),
    .s_axi_arvalid (s_axi_arvalid),
    .s_axi_arready (s_axi_arready),
    .s_axi_rdata   (s_axi_rdata),
    .s_axi_rresp   (s_axi_rresp),
    .s_axi_rvalid  (s_axi_rvalid),
    .s_axi_rready  (s_axi_rready),
    .pipeline_busy (pipeline_busy),
    .led           (led),
    .aperture      (aperture),
    .stat_rst      (stat_rst),
    .err_rst       (err_rst),
    .global_time   (global_time),
    .ar_id         (ar_id),
    .ar_addr       (ar_addr),
    .ar_len        (ar_len),
    .ar_valid      (ar_valid),
    .ar_ready      (ar_ready),
    .r_id          (r_id),
    .r_data        (r_data),
    .r_resp        (r_resp),
    .r_last        (r_last),
    .r_valid       (r_valid),
    .r_ready       (r_ready)
  );

endmodule
