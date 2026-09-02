//-----------------------------------------------------------------------
//Filename         : axis_cdc_inst.sv
//Description      : Instantiation template for axis_cdc_top.
//                 : Passes data width, FIFO depth, and synchronizer stages
//                 : to the VHDL core via mixed-language binding.
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------

`timescale 1ns/1ps
module axis_cdc_inst #(
    parameter int unsigned GC_TDATA_WIDTH = 32,  // payload width
    parameter int unsigned GC_CDC_DEPTH   = 8,   // FIFO depth (power of two)
    parameter int unsigned GC_SYNC_STAGES = 2    // synchronizer stages (2..4)
) ();
  logic s_axis_aclk;
  logic aresetn;
  logic [GC_TDATA_WIDTH-1:0] s_axis_tdata;
  logic s_axis_tvalid;
  logic s_axis_tready;
  logic m_axis_aclk;
  logic [GC_TDATA_WIDTH-1:0] m_axis_tdata;
  logic m_axis_tvalid;
  logic m_axis_tready;


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
