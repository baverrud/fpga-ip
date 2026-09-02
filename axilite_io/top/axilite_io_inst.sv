//-----------------------------------------------------------------------
//Filename         : axilite_io_inst.sv
//Description      : Instantiation template for axilite_io_top.
//                 : Passes the register/stream channel counts through
//                 : as parameters and exposes the full port set.
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------

`timescale 1ns/1ps
module axilite_io_inst #(
    parameter int unsigned NUM_ODATA   = 2,  // output register count
    parameter int unsigned NUM_IDATA   = 2,  // input port count
    parameter int unsigned NUM_OSTREAM = 2,  // AXI-Stream master count
    parameter int unsigned NUM_ISTREAM = 2   // AXI-Stream slave count
) ();
  logic aclk;
  logic aresetn;
  logic [15:0] s_axi_awaddr;
  logic [2:0] s_axi_awprot;
  logic s_axi_awvalid;
  logic s_axi_awready;
  logic [3:0][ 7:0] s_axi_wdata;
  logic [3:0] s_axi_wstrb;
  logic s_axi_wvalid;
  logic s_axi_wready;
  logic [1:0] s_axi_bresp;
  logic s_axi_bvalid;
  logic s_axi_bready;
  logic [15:0] s_axi_araddr;
  logic [2:0] s_axi_arprot;
  logic s_axi_arvalid;
  logic s_axi_arready;
  logic [31:0] s_axi_rdata;
  logic [1:0] s_axi_rresp;
  logic s_axi_rvalid;
  logic s_axi_rready;
  logic [NUM_ODATA-1:0][31:0] o_data;
  logic [NUM_IDATA-1:0][31:0] i_data;
  logic [31:0] m_axis_tdata;
  logic [NUM_OSTREAM-1:0] m_axis_tvalid;
  logic [NUM_ISTREAM-1:0][31:0] s_axis_tdata;
  logic [NUM_ISTREAM-1:0] s_axis_tready;


  axilite_io #(
      .NUM_ODATA   (NUM_ODATA),
      .NUM_IDATA   (NUM_IDATA),
      .NUM_OSTREAM (NUM_OSTREAM),
      .NUM_ISTREAM (NUM_ISTREAM)
  ) u_axilite_io (
      // Clock and reset
      .aclk    (aclk),
      .aresetn (aresetn),

      // AXI4-Lite slave write address channel
      .s_axi_awaddr  (s_axi_awaddr),
      .s_axi_awprot  (s_axi_awprot),
      .s_axi_awvalid (s_axi_awvalid),
      .s_axi_awready (s_axi_awready),

      // AXI4-Lite slave write data channel
      .s_axi_wdata  (s_axi_wdata),
      .s_axi_wstrb  (s_axi_wstrb),
      .s_axi_wvalid (s_axi_wvalid),
      .s_axi_wready (s_axi_wready),

      // AXI4-Lite slave write response channel
      .s_axi_bresp  (s_axi_bresp),
      .s_axi_bvalid (s_axi_bvalid),
      .s_axi_bready (s_axi_bready),

      // AXI4-Lite slave read address channel
      .s_axi_araddr  (s_axi_araddr),
      .s_axi_arprot  (s_axi_arprot),
      .s_axi_arvalid (s_axi_arvalid),
      .s_axi_arready (s_axi_arready),

      // AXI4-Lite slave read data channel
      .s_axi_rdata  (s_axi_rdata),
      .s_axi_rresp  (s_axi_rresp),
      .s_axi_rvalid (s_axi_rvalid),
      .s_axi_rready (s_axi_rready),

      // o_data registered outputs and i_data unregistered inputs
      .o_data (o_data),
      .i_data (i_data),

      // AXI-Stream outputs
      .m_axis_tdata  (m_axis_tdata),
      .m_axis_tvalid (m_axis_tvalid),

      // AXI-Stream inputs
      .s_axis_tdata  (s_axis_tdata),
      .s_axis_tready (s_axis_tready)
  );

endmodule
