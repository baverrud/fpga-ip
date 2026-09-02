//-----------------------------------------------------------------------
//Filename         : axis_cdc_top.sv
//Description      : Synthesis wrapper for axis_cdc (SystemVerilog).
//                 : Passes data width, FIFO depth, and synchronizer stages
//                 : to the VHDL core via mixed-language binding.
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------

`timescale 1ns/1ps

module axis_cdc_top #(
  parameter int unsigned GC_TDATA_WIDTH = 32,  // payload width
  parameter int unsigned GC_CDC_DEPTH   = 8,   // FIFO depth (power of two)
  parameter int unsigned GC_SYNC_STAGES = 2    // synchronizer stages (2..4)
) (
  // Source domain
  input  logic                      s_axis_aclk,    // source clock
  input  logic                      aresetn,        // shared reset (active low)
  input  logic [GC_TDATA_WIDTH-1:0] s_axis_tdata,   // payload to cross
  input  logic                      s_axis_tvalid,  // upstream valid
  output logic                      s_axis_tready,  // ready to accept

  // Destination domain
  input  logic                      m_axis_aclk,    // destination clock
  output logic [GC_TDATA_WIDTH-1:0] m_axis_tdata,   // crossed payload
  output logic                      m_axis_tvalid,  // valid crossed word
  input  logic                      m_axis_tready   // consumer ready
);

  // Instantiate the VHDL core (mixed-language binding).
  axis_cdc #(
    .GC_TDATA_WIDTH (GC_TDATA_WIDTH),
    .GC_CDC_DEPTH   (GC_CDC_DEPTH),
    .GC_SYNC_STAGES (GC_SYNC_STAGES)
  ) u_core (
    // Source domain
    .s_axis_aclk   (s_axis_aclk),
    .aresetn       (aresetn),
    .s_axis_tdata  (s_axis_tdata),
    .s_axis_tvalid (s_axis_tvalid),
    .s_axis_tready (s_axis_tready),

    // Destination domain
    .m_axis_aclk   (m_axis_aclk),
    .m_axis_tdata  (m_axis_tdata),
    .m_axis_tvalid (m_axis_tvalid),
    .m_axis_tready (m_axis_tready)
  );

endmodule
