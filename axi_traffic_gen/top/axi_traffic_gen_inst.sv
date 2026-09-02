//-----------------------------------------------------------------------
//Filename         : axi_traffic_gen_inst.sv
//Description      : Instantiation template for axi_req_gen_top.
//                 : Binds the VHDL core directly; passes the
//                 : configuration parameters through and exposes the
//                 : req channel plus runtime configuration and
//                 : statistics ports.
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------

`timescale 1ns/1ps
module axi_traffic_gen_inst #(
    parameter int unsigned GC_DATA_BYTES = 64,  // bytes per beat
    parameter int unsigned GC_ADDR_WIDTH = 32,  // address width
    parameter int unsigned GC_MAX_BURST  = 32   // max beats per burst
) ();
  logic aclk;
  logic aresetn;
  logic enable;
  logic aperture;
  logic stat_rst;
  logic [$clog2(GC_MAX_BURST)-1:0] cfg_req_len;
  logic cfg_len_mode;
  logic [$clog2(GC_MAX_BURST)-1:0] cfg_max_len;
  logic [31:0] cfg_pace;
  logic [31:0] cfg_pace_init;
  logic [GC_ADDR_WIDTH-1:0] cfg_base_addr;
  logic [GC_ADDR_WIDTH-1:0] cfg_addr_range;
  logic cfg_addr_mode;
  logic req_valid;
  logic req_ready;
  logic [GC_ADDR_WIDTH-1:0] req_addr;
  logic [$clog2(GC_MAX_BURST)-1:0] req_len;
  logic [31:0] stat_req_stall;
  logic [31:0] stat_req_issued;
  logic [31:0] stat_cfg_errors;


  axi_req_gen #(
      .GC_DATA_BYTES (GC_DATA_BYTES),
      .GC_ADDR_WIDTH (GC_ADDR_WIDTH),
      .GC_MAX_BURST  (GC_MAX_BURST)
  ) u_axi_req_gen (
      // Clock and reset
      .aclk    (aclk),
      .aresetn (aresetn),

      // Control
      .enable   (enable),
      .aperture (aperture),
      .stat_rst (stat_rst),

      // Runtime configuration
      .cfg_req_len    (cfg_req_len),
      .cfg_len_mode   (cfg_len_mode),
      .cfg_max_len    (cfg_max_len),
      .cfg_pace       (cfg_pace),
      .cfg_pace_init  (cfg_pace_init),
      .cfg_base_addr  (cfg_base_addr),
      .cfg_addr_range (cfg_addr_range),
      .cfg_addr_mode  (cfg_addr_mode),

      // Client request channel
      .req_valid (req_valid),
      .req_ready (req_ready),
      .req_addr  (req_addr),
      .req_len   (req_len),

      // Statistics
      .stat_req_stall  (stat_req_stall),
      .stat_req_issued (stat_req_issued),
      .stat_cfg_errors (stat_cfg_errors)
  );

endmodule
