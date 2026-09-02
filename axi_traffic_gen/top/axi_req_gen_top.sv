//-----------------------------------------------------------------------
//Filename         : axi_req_gen_top.sv
//Description      : Synthesis wrapper for axi_req_gen (SystemVerilog).
//                 : Binds the VHDL core directly; passes the
//                 : configuration parameters through and exposes the
//                 : req channel plus runtime configuration and
//                 : statistics ports.
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------

`timescale 1ns/1ps

module axi_req_gen_top #(
    parameter int unsigned GC_DATA_BYTES = 64,  // bytes per beat
    parameter int unsigned GC_ADDR_WIDTH = 32,  // address width
    parameter int unsigned GC_MAX_BURST  = 32   // max beats per burst
) (
    // Clock and reset
    input logic aclk,     // clock
    input logic aresetn,  // active-low synchronous reset

    // Control
    input logic enable,    // per-instance enable
    input logic aperture,  // measurement window
    input logic stat_rst,  // clears statistic counters

    // Runtime configuration
    input logic [$clog2(GC_MAX_BURST)-1:0] cfg_req_len,     // fixed request length (beats-1)
    input logic                            cfg_len_mode,    // 0 = fixed, 1 = random length
    input logic [$clog2(GC_MAX_BURST)-1:0] cfg_max_len,     // random length upper bound (beats-1)
    input logic [31:0]                     cfg_pace,        // idle cycles between reqs
    input logic [31:0]                     cfg_pace_init,   // delay before first burst
    input logic [GC_ADDR_WIDTH-1:0]        cfg_base_addr,   // window start
    input logic [GC_ADDR_WIDTH-1:0]        cfg_addr_range,  // window size
    input logic                            cfg_addr_mode,   // 0 = linear, 1 = random

    // Client request channel (master -> consumer)
    output logic                            req_valid,  // request valid
    input  logic                            req_ready,  // request ready
    output logic [GC_ADDR_WIDTH-1:0]        req_addr,   // request address
    output logic [$clog2(GC_MAX_BURST)-1:0] req_len,    // request length (beats-1)

    // Statistics
    output logic [31:0] stat_req_stall,   // req stall events
    output logic [31:0] stat_req_issued,  // reqs issued
    output logic [31:0] stat_cfg_errors   // config error count
);

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
