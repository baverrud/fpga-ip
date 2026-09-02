//-----------------------------------------------------------------------
//Filename         : axis_upsizer_top.sv
//Description      : Synthesis wrapper for axis_upsizer (SystemVerilog),
//                 : defaulted to the 128 -> 512-bit (4:1) configuration.
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------

`timescale 1ns/1ps

module axis_upsizer_top #(
    parameter int unsigned GC_S_TDATA_WIDTH = 128,  // narrow input width
    parameter int unsigned GC_RATIO         = 4,    // upsize ratio
    parameter int unsigned GC_ID_WIDTH      = 4     // AXI R ID width
) (
    // Clock / reset
    input logic aclk,
    input logic aresetn,

    // Slave interface (narrow input, AXI R channel)
    input  logic [GC_S_TDATA_WIDTH-1:0] s_axis_tdata,
    input  logic                        s_axis_tlast,
    input  logic [1:0]                  s_axis_rresp,
    input  logic [GC_ID_WIDTH-1:0]      s_axis_rid,
    input  logic                        s_axis_tvalid,
    output logic                        s_axis_tready,

    // Master interface (wide output, AXI R channel)
    output logic [GC_S_TDATA_WIDTH*GC_RATIO-1:0] m_axis_tdata,
    output logic                                 m_axis_tlast,
    output logic [1:0]                           m_axis_rresp,
    output logic [GC_ID_WIDTH-1:0]               m_axis_rid,
    output logic                                 m_axis_tvalid,
    input  logic                                 m_axis_tready
);

  axis_upsizer #(
      .GC_S_TDATA_WIDTH (GC_S_TDATA_WIDTH),
      .GC_RATIO         (GC_RATIO),
      .GC_ID_WIDTH      (GC_ID_WIDTH)
  ) u_core (
      .aclk          (aclk),
      .aresetn       (aresetn),
      .s_axis_tdata  (s_axis_tdata),
      .s_axis_tlast  (s_axis_tlast),
      .s_axis_rresp  (s_axis_rresp),
      .s_axis_rid    (s_axis_rid),
      .s_axis_tvalid (s_axis_tvalid),
      .s_axis_tready (s_axis_tready),
      .m_axis_tdata  (m_axis_tdata),
      .m_axis_tlast  (m_axis_tlast),
      .m_axis_rresp  (m_axis_rresp),
      .m_axis_rid    (m_axis_rid),
      .m_axis_tvalid (m_axis_tvalid),
      .m_axis_tready (m_axis_tready)
  );

endmodule
