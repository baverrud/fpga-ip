//-----------------------------------------------------------------------
//Filename         : pulse_extender_inst.sv
//Description      : Instantiation template for pulse_extender_top.
//                 : Passes the pulse-length generic through to the core.
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------

`timescale 1ns/1ps
module pulse_extender_inst #(
  // Pulse configuration
  parameter int unsigned GC_PULSE_LEN = 4  // output pulse length in clock cycles
) ();
  logic clk;
  logic rstn;
  logic trigger;
  logic pulse_out;


  // Instantiate the VHDL core (mixed-language binding).
  pulse_extender #(
    .GC_PULSE_LEN (GC_PULSE_LEN)
  ) u_pulse_extender (
  // Clock, reset, and trigger
    .clk     (clk),
    .rstn    (rstn),
    .trigger (trigger),

  // Extended output pulse
    .pulse_out (pulse_out)
  );

endmodule
