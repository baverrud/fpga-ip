//-----------------------------------------------------------------------
//Filename         : axis_downsizer_inst.sv
//Description      : Instantiation template for axis_downsizer_top.
//                 : defaulted to the 512 -> 128-bit (4:1) configuration.
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------

`timescale 1ns/1ps
module axis_downsizer_inst #(
  parameter int unsigned GC_M_TDATA_WIDTH = 128,  // narrow output width
  parameter int unsigned GC_RATIO         = 4,    // downsize ratio
  parameter int unsigned GC_ID_WIDTH      = 4     // AXI R ID width
) ();
  logic aclk;
  logic aresetn;
  logic [GC_M_TDATA_WIDTH*GC_RATIO-1:0] s_axis_tdata;
  logic s_axis_tlast;
  logic [1:0] s_axis_rresp;
  logic [GC_ID_WIDTH-1:0] s_axis_rid;
  logic s_axis_tvalid;
  logic s_axis_tready;
  logic [GC_M_TDATA_WIDTH-1:0] m_axis_tdata;
  logic m_axis_tlast;
  logic [1:0] m_axis_rresp;
  logic [GC_ID_WIDTH-1:0] m_axis_rid;
  logic m_axis_tvalid;
  logic m_axis_tready;


  axis_downsizer #(
    .GC_M_TDATA_WIDTH (GC_M_TDATA_WIDTH),
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
