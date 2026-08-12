//-----------------------------------------------------------------------
//Filename         : axi_ar_mux_top_sv_tb.sv
//Description      : Mixed-language smoke test for the SystemVerilog wrapper.
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------
`timescale 1ns/1ps

module axi_ar_mux_top_sv_tb;
  localparam int unsigned C_NUM_CLIENTS = 2;

  logic aclk = 1'b0;
  logic aresetn = 1'b0;
  logic [C_NUM_CLIENTS-1:0][31:0] req_addr = '0;
  logic [C_NUM_CLIENTS-1:0][5:0] req_len = '0;
  logic [C_NUM_CLIENTS-1:0] req_valid = '0;
  logic [C_NUM_CLIENTS-1:0] req_ready;
  logic [C_NUM_CLIENTS-1:0] r_pop = '0;
  logic [3:0] ar_id;
  logic [31:0] ar_addr;
  logic [7:0] ar_len;
  logic [2:0] ar_size;
  logic [1:0] ar_burst;
  logic ar_valid;
  logic ar_ready = 1'b1;

  axi_ar_mux_top #(
      .GC_NUM_CLIENTS (C_NUM_CLIENTS),
      .GC_ADDR_WIDTH  (32),
      .GC_ID_WIDTH    (4),
      .GC_FIFO_DEPTH  (8),
      .GC_CLIENT_DATA_WIDTH (512),
      .GC_NATIVE_DATA_WIDTH (128),
      .GC_CLIENT_ARLEN_WIDTH (6),
      .GC_NATIVE_ARLEN_WIDTH (8)
  ) dut (
      .aclk      (aclk),
      .aresetn   (aresetn),
      .req_addr  (req_addr),
      .req_len   (req_len),
      .req_valid (req_valid),
      .req_ready (req_ready),
      .r_pop     (r_pop),
      .ar_id     (ar_id),
      .ar_addr   (ar_addr),
      .ar_len    (ar_len),
      .ar_size   (ar_size),
      .ar_burst  (ar_burst),
      .ar_valid  (ar_valid),
      .ar_ready  (ar_ready)
  );

  always #2 aclk = ~aclk;

  task automatic fail(input string message);
    begin
      $display("** Failure: %s", message);
      $finish;
    end
  endtask

  task automatic send_request(
      input int unsigned client,
      input logic [31:0] address,
      input logic [7:0]  length
  );
    int unsigned wait_count;
    begin
      @(negedge aclk);
      req_addr[client] = address;
      req_len[client] = length;
      req_valid[client] = 1'b1;
      #1;
      wait_count = 0;
      while (req_ready[client] !== 1'b1) begin
        if (wait_count == 100) begin
          fail($sformatf("SV wrapper request timeout for client %0d", client));
        end
        @(negedge aclk);
        #1;
        wait_count++;
      end
      @(posedge aclk);
      #1;
      req_valid[client] = 1'b0;
    end
  endtask

  task automatic wait_for_ar(
      input int unsigned client,
      input logic [31:0] address
  );
    int unsigned wait_count;
    begin
      wait_count = 0;
      while (!(ar_valid && ar_id == client[3:0] && ar_addr == address)) begin
        if (wait_count == 100) begin
          fail($sformatf("SV wrapper AR timeout for client %0d", client));
        end
        @(posedge aclk);
        #1;
        wait_count++;
      end
      if (ar_len != 8'h03 || ar_size != 3'b100 || ar_burst != 2'b01) begin
        fail("SV wrapper AR payload mismatch");
      end
    end
  endtask

  initial begin
    repeat (2) @(posedge aclk);
    aresetn = 1'b1;
    @(negedge aclk);

    send_request(0, 32'h0000_0100, 8'h00);
    wait_for_ar(0, 32'h0000_0100);
    @(posedge aclk);
    #1;
    if (ar_valid) begin
      fail("SV wrapper client 0 AR did not handshake");
    end

    ar_ready = 1'b0;
    send_request(0, 32'h0000_0200, 8'h00);
    wait_for_ar(0, 32'h0000_0200);
    #1;
    if (!ar_valid || ar_id != 4'd0 || ar_addr != 32'h0000_0200) begin
      fail("SV wrapper locked payload mismatch");
    end

    send_request(1, 32'h1000_0300, 8'h00);
    #1;
    if (!ar_valid || ar_id != 4'd0 || ar_addr != 32'h0000_0200) begin
      fail("SV wrapper pending request changed locked AR");
    end

    ar_ready = 1'b1;
    wait_for_ar(1, 32'h1000_0300);

    $display("ALL SV AR-MUX WRAPPER CHECKS PASSED");
    $finish;
  end
endmodule
