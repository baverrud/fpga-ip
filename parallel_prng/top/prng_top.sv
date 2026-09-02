//-----------------------------------------------------------------------
//Filename         : prng_top.sv
//Description      : Top wrapper exporting all parallel_prng modules
//                 : (SystemVerilog).  Instantiates xorshift32 and
//                 : xorshift128 (VHDL, mixed-language binding).
//                 : Both run free-running (tie step internally) or
//                 : accept external step control via dedicated ports.
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------

`timescale 1ns/1ps

module prng_top (
  // Clock and reset
  input logic clk,   // clock
  input logic rstn,  // active-low synchronous reset

  // xorshift32 control and output
  input  logic        step32,
  output logic [31:0] data32,

  // xorshift128 control and output
  input  logic        step128,
  output logic [63:0] data128
);

  xorshift32 #(
    .GC_SEED (32'hDEADBEEF)
  ) u_xorshift32 (
    // Clock, reset, and xorshift32 control
    .clk  (clk),
    .rstn (rstn),
    .step (step32),
    .data (data32)
  );

  xorshift128 #(
    .GC_SEED0 (64'hDEADBEEFCAFEBABE),
    .GC_SEED1 (64'h0123456789ABCDEF)
  ) u_xorshift128 (
    // Clock, reset, and xorshift128 control
    .clk  (clk),
    .rstn (rstn),
    .step (step128),
    .data (data128)
  );

endmodule
