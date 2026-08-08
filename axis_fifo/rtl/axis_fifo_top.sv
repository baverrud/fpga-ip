//-----------------------------------------------------------------------
//Filename         : axis_fifo_top.sv
//Description      : Synthesis wrapper for axis_fifo (SystemVerilog).
//                 : Passes the data-width and FIFO-depth parameters
//                 : through to the core.
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------

`timescale 1ns/1ps

module axis_fifo_top #(
    // Data path and storage
    parameter int unsigned GC_TDATA_WIDTH = 8,  // data path width (bits)
    parameter int unsigned GC_FIFO_DEPTH  = 64  // FIFO depth (entries)
) (
    // Clock and reset
    input logic aclk,     // clock
    input logic aresetn,  // active-low synchronous reset

    // Slave AXI4-Stream interface
    input  logic [GC_TDATA_WIDTH-1:0] s_axis_tdata,   // input data
    input  logic                      s_axis_tvalid,  // input valid
    output logic                      s_axis_tready,  // input ready

    // Master AXI4-Stream interface
    output logic [GC_TDATA_WIDTH-1:0] m_axis_tdata,   // output data
    output logic                      m_axis_tvalid,  // output valid
    input  logic                      m_axis_tready,  // output ready

    // FIFO occupancy
    output logic [$clog2(GC_FIFO_DEPTH):0] fifo_count  // occupancy count
);

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
