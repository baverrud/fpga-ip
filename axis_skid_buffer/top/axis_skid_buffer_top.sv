//-----------------------------------------------------------------------
//Filename         : axis_skid_buffer_top.sv
//Description      : Synthesis wrapper for axis_skid_buffer (SystemVerilog).
//                 : Passes the data-width parameter through to the core.
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------

`timescale 1ns/1ps

module axis_skid_buffer_top #(
  // Data path
  parameter int unsigned GC_TDATA_WIDTH = 8  // data path width (bits)
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
    input  logic                      m_axis_tready   // output ready
);

  axis_skid_buffer #(
    .GC_TDATA_WIDTH (GC_TDATA_WIDTH)
  ) u_axis_skid_buffer (
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
    .m_axis_tready (m_axis_tready)
  );

endmodule
