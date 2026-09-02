//-----------------------------------------------------------------------
//Filename         : axis_fifo_inst.sv
//Description      : Instantiation template for axis_fifo_top.
//                 : Passes the data-width and FIFO-depth parameters
//                 : through to the core.
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------

`timescale 1ns/1ps
module axis_fifo_inst #(
    // Data path and storage
    parameter int unsigned GC_TDATA_WIDTH = 8,  // data path width (bits)
    parameter int unsigned GC_FIFO_DEPTH  = 64  // FIFO depth (entries)
) ();
  logic aclk;
  logic aresetn;
  logic [GC_TDATA_WIDTH-1:0] s_axis_tdata;
  logic s_axis_tvalid;
  logic s_axis_tready;
  logic [GC_TDATA_WIDTH-1:0] m_axis_tdata;
  logic m_axis_tvalid;
  logic m_axis_tready;
  logic [$clog2(GC_FIFO_DEPTH):0] fifo_count;


  axis_fifo #(
      .GC_TDATA_WIDTH (GC_TDATA_WIDTH),
      .GC_FIFO_DEPTH  (GC_FIFO_DEPTH)
  ) u_axis_fifo (
      // Clock and reset
      .aclk    (aclk),
      .aresetn (aresetn),

      // Slave AXI4-Stream interface
      .s_axis_tdata  (s_axis_tdata),
      .s_axis_tvalid (s_axis_tvalid),
      .s_axis_tready (s_axis_tready),

    // Master AXI4-Stream interface
      .m_axis_tdata  (m_axis_tdata),
      .m_axis_tvalid (m_axis_tvalid),
      .m_axis_tready (m_axis_tready),

    // FIFO occupancy
      .fifo_count (fifo_count)
  );

endmodule
