//-----------------------------------------------------------------------
//Filename         : axi_ar_gen_top.sv
//Description      : Synthesis wrapper for axi_ar_gen (SystemVerilog).
//                 : Binds the VHDL core directly; passes the AXI
//                 : configuration parameters through and exposes the
//                 : AR channel plus runtime configuration and
//                 : statistics ports.
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------

`timescale 1ns/1ps

module axi_ar_gen_top #(
    parameter int unsigned GC_DATA_BYTES = 16,  // bytes per beat
    parameter int unsigned GC_ADDR_WIDTH = 49,  // AXI address width
    parameter int unsigned GC_ID_WIDTH   = 6,   // AXI ID width
    parameter int unsigned GC_MAX_BURST  = 256  // max beats per burst
) (
    // Clock and reset
    input logic aclk,     // clock
    input logic aresetn,  // active-low synchronous reset

    // Control
    input logic enable,    // per-instance enable
    input logic aperture,  // measurement window
    input logic stat_rst,  // clears statistic counters

    // Runtime configuration
    input logic [GC_ID_WIDTH-1:0]          cfg_id,          // AR ID to tag each burst
    input logic [$clog2(GC_MAX_BURST)-1:0] cfg_arlen,       // AXI arlen (beats-1)
    input logic [31:0]                     cfg_pace,        // idle cycles between ARs
    input logic [31:0]                     cfg_pace_init,   // delay before first burst
    input logic [GC_ADDR_WIDTH-1:0]        cfg_base_addr,   // window start
    input logic [GC_ADDR_WIDTH-1:0]        cfg_addr_range,  // window size
    input logic                            cfg_addr_mode,   // 0 = linear, 1 = random

    // AXI Read-Address Channel (master -> DUT)
    output logic                     ar_valid,  // address valid
    input  logic                     ar_ready,  // address ready
    output logic [GC_ID_WIDTH-1:0]   ar_id,     // AR ID
    output logic [GC_ADDR_WIDTH-1:0] ar_addr,   // AR address
    output logic [7:0]               ar_len,    // burst length (beats-1)
    output logic [2:0]               ar_size,   // bytes per beat
    output logic [1:0]               ar_burst,  // burst type (always INCR)

    // Statistics
    output logic [31:0] stat_ar_stall,   // AR stall events
    output logic [31:0] stat_ar_issued,  // ARs issued
    output logic [31:0] stat_cfg_errors  // config error count
);

  axi_ar_gen #(
      .GC_DATA_BYTES (GC_DATA_BYTES),
      .GC_ADDR_WIDTH (GC_ADDR_WIDTH),
      .GC_ID_WIDTH   (GC_ID_WIDTH),
      .GC_MAX_BURST  (GC_MAX_BURST)
  ) u_axi_ar_gen (
      // Clock and reset
      .aclk    (aclk),
      .aresetn (aresetn),

      // Control
      .enable   (enable),
      .aperture (aperture),
      .stat_rst (stat_rst),

      // Runtime configuration
      .cfg_id         (cfg_id),
      .cfg_arlen      (cfg_arlen),
      .cfg_pace       (cfg_pace),
      .cfg_pace_init  (cfg_pace_init),
      .cfg_base_addr  (cfg_base_addr),
      .cfg_addr_range (cfg_addr_range),
      .cfg_addr_mode  (cfg_addr_mode),

      // AXI Read-Address Channel
      .ar_valid (ar_valid),
      .ar_ready (ar_ready),
      .ar_id    (ar_id),
      .ar_addr  (ar_addr),
      .ar_len   (ar_len),
      .ar_size  (ar_size),
      .ar_burst (ar_burst),

      // Statistics
      .stat_ar_stall   (stat_ar_stall),
      .stat_ar_issued  (stat_ar_issued),
      .stat_cfg_errors (stat_cfg_errors)
  );

endmodule
