//-----------------------------------------------------------------------
//Filename         : jitter_gen_inst.sv
//Description      : Instantiation template for jitter_gen_top.
//                 : Passes all generics through to the CDF-based jitter
//                 : generator with its selectable internal PRNG (VHDL,
//                 : mixed-language binding).
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------

`timescale 1ns/1ps
module jitter_gen_inst #(
    // Jitter generator and PRNG configuration
    parameter int unsigned GC_JITTER_WIDTH    = 8,
    parameter bit          GC_USE_XORSHIFT128 = 0,
    parameter logic [31:0] GC_SEED            = 32'hDEADBEEF,
    parameter logic [63:0] GC_SEED0           = 64'hDEADBEEFCAFEBABE,
    parameter logic [63:0] GC_SEED1           = 64'h0123456789ABCDEF,
    parameter int          GC_VAL_0           = 0,
    parameter int          GC_VAL_1           = 1,
    parameter int          GC_VAL_2           = 3,
    parameter int          GC_VAL_3           = 7,
    parameter int          GC_TH_0            = 128,
    parameter int          GC_TH_1            = 192,
    parameter int          GC_TH_2            = 240
) ();
  logic clk;
  logic rstn;
  logic step;
  logic enable;
  logic [GC_JITTER_WIDTH-1:0] jitter;


  jitter_gen #(
      .GC_JITTER_WIDTH    (GC_JITTER_WIDTH),
      .GC_USE_XORSHIFT128 (GC_USE_XORSHIFT128),
      .GC_SEED            (GC_SEED),
      .GC_SEED0           (GC_SEED0),
      .GC_SEED1           (GC_SEED1),
      .GC_VAL_0           (GC_VAL_0),
      .GC_VAL_1           (GC_VAL_1),
      .GC_VAL_2           (GC_VAL_2),
      .GC_VAL_3           (GC_VAL_3),
      .GC_TH_0            (GC_TH_0),
      .GC_TH_1            (GC_TH_1),
      .GC_TH_2            (GC_TH_2)
  ) u_jitter_gen (
      // Clock, reset, and controls
    .clk    (clk),
    .rstn   (rstn),
    .step   (step),
    .enable (enable),

      // Generated jitter value
      .jitter (jitter)
  );

endmodule
