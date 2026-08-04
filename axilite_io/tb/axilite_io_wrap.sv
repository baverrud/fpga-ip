//-----------------------------------------------------------------------
//Filename         : axilite_io_wrap.sv
//Description      : SV flattened-port wrapper for axilite_io.
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------
// =====================================================================
// axilite_io_wrap.sv -- SV wrapper with flattened ports
// =====================================================================
// WHY THIS WRAPPER EXISTS
// ------------------------
// The SV DUT (axilite_io.sv) uses packed 2D arrays for its multi-slot
// data ports -- e.g. `o_data [NUM_ODATA-1:0][31:0]`.  VHDL cannot
// directly instantiate an SV module that uses packed arrays because
// VHDL's std_logic_vector is a 1D type.  Conversely, the VHDL DUT
// (axilite_io.vhd) uses t_slv32_array (an array of 32-bit vectors)
// which SV cannot directly bind to either.
//
// Each wrapper (one per language) normalises these to a common
// flattened std_logic_vector interface.  The axilite_io_harness
// instantiates axilite_io_wrap by entity, testing one DUT per run.
// =====================================================================
module axilite_io_wrap
#(NUM_ODATA   = 2,
  NUM_IDATA   = 2,
  NUM_OSTREAM = 2,
  NUM_ISTREAM = 2)
(
  input  wire                    aclk         ,
  input  wire                    aresetn      ,
  
  input  wire             [15:0] s_axi_awaddr ,
  input  wire             [ 2:0] s_axi_awprot ,
  input  wire                    s_axi_awvalid,
  output reg                     s_axi_awready,
  
  input  wire             [31:0] s_axi_wdata  ,
  input  wire             [ 3:0] s_axi_wstrb  ,
  input  wire                    s_axi_wvalid ,
  output reg                     s_axi_wready ,
  
  output reg              [ 1:0] s_axi_bresp  ,
  output reg                     s_axi_bvalid ,
  input  wire                    s_axi_bready ,
  
  input  wire             [15:0] s_axi_araddr ,
  input  wire             [ 2:0] s_axi_arprot ,
  input  wire                    s_axi_arvalid,
  output reg                     s_axi_arready,
  
  output reg              [31:0] s_axi_rdata  ,
  output reg              [ 1:0] s_axi_rresp  ,
  output reg                     s_axi_rvalid ,
  input  wire                    s_axi_rready ,
  
  // Flattened arrays: o_data[N*32-1:0], i_data[N*32-1:0], s_axis_tdata[N*32-1:0]
  output reg [NUM_ODATA*32-1:0]   o_data,
  input  wire [NUM_IDATA*32-1:0]  i_data,
  
  output reg                 [31:0] m_axis_tdata ,
  output reg [NUM_OSTREAM-1:0]     m_axis_tvalid,
  
  input  wire [NUM_ISTREAM*32-1:0] s_axis_tdata ,
  output reg [NUM_ISTREAM-1:0]     s_axis_tready
);

  // Internal packed-array signals
  logic [NUM_ODATA-1:0][31:0]   o_data_pack;
  logic [NUM_IDATA-1:0][31:0]   i_data_pack;
  logic [NUM_ISTREAM-1:0][31:0] s_axis_tdata_pack;

  // Instantiate the SV DUT
  axilite_io #(
    .NUM_ODATA  (NUM_ODATA),
    .NUM_IDATA  (NUM_IDATA),
    .NUM_OSTREAM(NUM_OSTREAM),
    .NUM_ISTREAM(NUM_ISTREAM)
  ) core (
    .aclk          (aclk         ),
    .aresetn       (aresetn      ),
    .s_axi_awaddr  (s_axi_awaddr ),
    .s_axi_awprot  (s_axi_awprot ),
    .s_axi_awvalid (s_axi_awvalid),
    .s_axi_awready (s_axi_awready),
    .s_axi_wdata   (s_axi_wdata  ),
    .s_axi_wstrb   (s_axi_wstrb  ),
    .s_axi_wvalid  (s_axi_wvalid ),
    .s_axi_wready  (s_axi_wready ),
    .s_axi_bresp   (s_axi_bresp  ),
    .s_axi_bvalid  (s_axi_bvalid ),
    .s_axi_bready  (s_axi_bready ),
    .s_axi_araddr  (s_axi_araddr ),
    .s_axi_arprot  (s_axi_arprot ),
    .s_axi_arvalid (s_axi_arvalid),
    .s_axi_arready (s_axi_arready),
    .s_axi_rdata   (s_axi_rdata  ),
    .s_axi_rresp   (s_axi_rresp  ),
    .s_axi_rvalid  (s_axi_rvalid ),
    .s_axi_rready  (s_axi_rready ),
    .o_data        (o_data_pack  ),
    .i_data        (i_data_pack  ),
    .m_axis_tdata  (m_axis_tdata ),
    .m_axis_tvalid (m_axis_tvalid),
    .s_axis_tdata  (s_axis_tdata_pack),
    .s_axis_tready (s_axis_tready)
  );

  // Pack <=> Flat conversion
  always_comb begin
    for (int i = 0; i < NUM_ODATA; i++)
      o_data[i*32 +: 32] = o_data_pack[i];
    for (int i = 0; i < NUM_IDATA; i++)
      i_data_pack[i] = i_data[i*32 +: 32];
    for (int i = 0; i < NUM_ISTREAM; i++)
      s_axis_tdata_pack[i] = s_axis_tdata[i*32 +: 32];
  end

endmodule
