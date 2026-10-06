//-----------------------------------------------------------------------
//Filename         : axi_read_bridge_no_cdc_inst.sv
//Description      : SystemVerilog instantiation template.
//Author           : Rune Baeverrud
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------

module axi_read_bridge_no_cdc_inst;
  localparam int unsigned GC_NUM_CLIENTS = 4;
  localparam int unsigned GC_ADDR_WIDTH = 32;
  localparam int unsigned GC_ID_WIDTH = 4;

  logic aclk;
  logic aresetn;
  logic [GC_NUM_CLIENTS-1:0][GC_ADDR_WIDTH-1:0] req_addr;
  logic [GC_NUM_CLIENTS-1:0][7:0] req_len;
  logic [GC_NUM_CLIENTS-1:0] req_valid;
  logic [GC_NUM_CLIENTS-1:0] req_ready;
  logic [GC_NUM_CLIENTS-1:0][511:0] rsp_data;
  logic [GC_NUM_CLIENTS-1:0][1:0] rsp_resp;
  logic [GC_NUM_CLIENTS-1:0] rsp_last;
  logic [GC_NUM_CLIENTS-1:0] rsp_valid;
  logic [GC_NUM_CLIENTS-1:0] rsp_ready;
  logic [GC_ID_WIDTH-1:0] ar_id;
  logic [GC_ADDR_WIDTH-1:0] ar_addr;
  logic [7:0] ar_len;
  logic [2:0] ar_size;
  logic ar_valid;
  logic ar_ready;
  logic [GC_ID_WIDTH-1:0] r_id;
  logic [511:0] r_data;
  logic [1:0] r_resp;
  logic r_last;
  logic r_valid;
  logic r_ready;

  axi_read_bridge_no_cdc_top u_dut (.*);
endmodule