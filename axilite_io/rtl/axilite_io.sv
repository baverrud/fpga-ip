//-----------------------------------------------------------------------
//Filename         : axilite_io.sv
//Description      : AXI4-Lite Slave to Register & Stream Bridge (SystemVerilog):
//                 :  - Single-beat AXI4-Lite slave, 16-bit addr, 32-bit data.
//                 :  - Output registers (NUM_ODATA x 32-bit) writable via
//                 :    AXI4-Lite with byte-enable support (wstrb).
//                 :  - Input ports (NUM_IDATA x 32-bit) readable from bus.
//                 :  - AXI-Stream output channels (NUM_OSTREAM): write to
//                 :    address region 0x4000+ to push data.
//                 :  - AXI-Stream input channels (NUM_ISTREAM): read from
//                 :    address region 0xC000+ to pop data.
//                 :  - Address map: o_data at 0x0000, stream push at 0x4000,
//                 :    i_data at 0x8000, stream pop at 0xC000.
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//                 : Permission to use, copy, modify, and/or distribute this
//                 : software for any purpose with or without fee is hereby granted.
//-----------------------------------------------------------------------
`default_nettype none

module axilite_io
#(NUM_ODATA   = 2, // Number of o_data register outputs
  NUM_IDATA   = 2, // Number of i_data inputs
  NUM_OSTREAM = 2, // Number of axi-stream outputs
  NUM_ISTREAM = 2) // Number of axi-stream inputs
(
  input wire aclk,
  input wire aresetn,

  input  wire [15:0] s_axi_awaddr,
  input  wire [2:0]  s_axi_awprot,
  input  wire        s_axi_awvalid,
  output reg         s_axi_awready,

  input  wire [3:0][ 7:0] s_axi_wdata,
  input  wire [3:0]       s_axi_wstrb,
  input  wire             s_axi_wvalid,
  output reg              s_axi_wready,

  output reg [1:0] s_axi_bresp,
  output reg       s_axi_bvalid,
  input  wire      s_axi_bready,

  input  wire [15:0] s_axi_araddr,
  input  wire [2:0]  s_axi_arprot,
  input  wire        s_axi_arvalid,
  output reg         s_axi_arready,

  output reg [31:0] s_axi_rdata,
  output reg [1:0]  s_axi_rresp,
  output reg        s_axi_rvalid,
  input  wire       s_axi_rready,

  // o_data registered outputs and i_data unregistered inputs
  output reg [NUM_ODATA-1:0][31:0]  o_data,
  input  wire [NUM_IDATA-1:0][31:0] i_data,

  // AXI-Stream outputs
  output reg [31:0]            m_axis_tdata,
  output reg [NUM_OSTREAM-1:0] m_axis_tvalid,
//input  wire                        m_axis_tready, // NOT IMPLEMENTED

  // AXI-Stream inputs
  input wire [NUM_ISTREAM-1:0][31:0] s_axis_tdata,
//input  wire                        s_axis_tvalid, // NOT IMPLEMENTED
  output reg [NUM_ISTREAM-1:0] s_axis_tready
);

typedef struct {
  logic [NUM_ODATA-1:0][3:0][7:0] oregs;
  logic [31:0]                    rdata;
  logic                           rvalid;
  logic                           bvalid;
} rec_t;

const rec_t C_REC_DEFAULT = '{
  oregs  : '0,
  rdata : 'x,
  rvalid: '0,
  bvalid: '0
};

rec_t r = C_REC_DEFAULT;
rec_t v;

always_comb begin
  v = r;

  // all input readys default de-asserted
  s_axi_awready = 0;
  s_axi_wready  = 0;
  s_axi_arready = 0;
  s_axis_tready = 0;

  // all output valids are default de-asserted
  m_axis_tdata  = 'x;
  m_axis_tvalid = 0;

  // s_axi_r* output
  s_axi_rdata   = r.rdata;
  s_axi_rresp   = 0;
  s_axi_rvalid  = r.rvalid;

  // s_axi_b* output
  s_axi_bresp   = 0;
  s_axi_bvalid  = r.bvalid;

  // if WRITE OPERATION
  if (s_axi_awvalid && s_axi_wvalid && !r.bvalid ) begin
    // *always* ack write command
    s_axi_awready = 1;
    s_axi_wready  = 1;
    v.bvalid      = 1; // write OK

    // write to register with byte enables
    case (s_axi_awaddr[15:14])
      0: for (int i=0; i<4; i++)
           if (s_axi_wstrb[i])
             //v.oregs[s_axi_awaddr[7:2]][i] = s_axi_wdata[i];
             v.oregs[s_axi_awaddr[$clog2(NUM_ODATA)+1:2]][i] = s_axi_wdata[i];
      1: begin
           m_axis_tdata  = s_axi_wdata;
           m_axis_tvalid[s_axi_awaddr[$clog2(NUM_OSTREAM)+1:2]] = 1;
         end
      2: ;
      3: ;
    endcase
  end

  // if READ OPERATION
  if (s_axi_arvalid && !r.rvalid) begin
    case (s_axi_araddr[15:14])
      0: v.rdata = r.oregs[s_axi_araddr[$clog2(NUM_ODATA)+1:2]];
      1: v.rdata = 0;
      2: v.rdata = i_data [s_axi_araddr[$clog2(NUM_IDATA)+1:2]];
      3: begin
           v.rdata = s_axis_tdata[s_axi_araddr[$clog2(NUM_ISTREAM)+1:2]];
           s_axis_tready[s_axi_araddr[$clog2(NUM_ISTREAM)+1:2]] = 1;
         end
    endcase
    v.rvalid = 1;
    s_axi_arready = 1;
  end

  if (r.bvalid && s_axi_bready) v.bvalid = 0; // clear bvalid whenever s_axi_bresp is read.
  if (r.rvalid && s_axi_rready) v.rvalid = 0; // clear rvalid whenever s_axi_rdata is read.

  o_data = r.oregs;
end

always_ff @(posedge aclk)
  if (!aresetn)
    r <= C_REC_DEFAULT;
  else
    r <= v;

endmodule

`default_nettype wire
