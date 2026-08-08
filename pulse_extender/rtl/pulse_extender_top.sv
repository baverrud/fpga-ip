//-----------------------------------------------------------------------
//Filename         : pulse_extender_top.sv
//Description      : Synthesis wrapper for pulse_extender (SystemVerilog).
//                 : Passes the pulse-length generic through to the core.
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------

`timescale 1ns/1ps

module pulse_extender_top #(
    parameter int unsigned GC_PULSE_LEN = 4   // output pulse length in clock cycles
) (
    input  logic clk,         // clock
    input  logic rstn,        // active-low synchronous reset
    input  logic trigger,     // trigger input, sampled only while idle
    output logic pulse_out    // extended output pulse
);

  // Instantiate the VHDL core (mixed-language binding).
  pulse_extender #(
      .GC_PULSE_LEN (GC_PULSE_LEN)
  ) u_pulse_extender (
      .clk       (clk),
      .rstn      (rstn),
      .trigger   (trigger),
      .pulse_out (pulse_out)
  );

endmodule
