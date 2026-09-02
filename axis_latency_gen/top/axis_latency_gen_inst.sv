//-----------------------------------------------------------------------
//Filename         : axis_latency_gen_inst.sv
//Description      : Instantiation template for axis_latency_gen_top.
//                 : Passes all generics and ports through to the core
//                 : (VHDL, mixed-language binding).
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------

`timescale 1ns/1ps
module axis_latency_gen_inst #(
    // Data path
    parameter int unsigned GC_DATA_WIDTH  = 32,
    parameter int unsigned GC_FIFO_DEPTH  = 16,
    parameter int unsigned GC_TIMER_WIDTH = 32,

    // Jitter generator (passed through to jitter_gen)
    parameter int unsigned GC_JG_JITTER_WIDTH = 8,
    parameter bit          GC_USE_XORSHIFT128 = 0,
    parameter logic [31:0] GC_JG_SEED         = 32'hDEADBEEF,
    parameter logic [63:0] GC_JG_SEED0        = 64'hDEADBEEFCAFEBABE,
    parameter logic [63:0] GC_JG_SEED1        = 64'h0123456789ABCDEF,
    parameter int          GC_JG_VAL_0        = 0,
    parameter int          GC_JG_VAL_1        = 1,
    parameter int          GC_JG_VAL_2        = 3,
    parameter int          GC_JG_VAL_3        = 7,
    parameter int          GC_JG_TH_0         = 128,
    parameter int          GC_JG_TH_1         = 192,
    parameter int          GC_JG_TH_2         = 240
) ();
  logic aclk;
  logic aresetn;
  logic [GC_DATA_WIDTH-1:0] s_axis_tdata;
  logic s_axis_tvalid;
  logic s_axis_tready;
  logic [GC_DATA_WIDTH-1:0] m_axis_tdata;
  logic m_axis_tvalid;
  logic m_axis_tready;
  logic [GC_TIMER_WIDTH-1:0] base_delay;
  logic enable_base_delay;
  logic enable_jitter;
  logic [$clog2(GC_FIFO_DEPTH):0] fifo_count;


  axis_latency_gen #(
      .GC_DATA_WIDTH      (GC_DATA_WIDTH),
      .GC_FIFO_DEPTH      (GC_FIFO_DEPTH),
      .GC_TIMER_WIDTH     (GC_TIMER_WIDTH),
      .GC_JG_JITTER_WIDTH (GC_JG_JITTER_WIDTH),
      .GC_USE_XORSHIFT128 (GC_USE_XORSHIFT128),
      .GC_JG_SEED         (GC_JG_SEED),
      .GC_JG_SEED0        (GC_JG_SEED0),
      .GC_JG_SEED1        (GC_JG_SEED1),
      .GC_JG_VAL_0        (GC_JG_VAL_0),
      .GC_JG_VAL_1        (GC_JG_VAL_1),
      .GC_JG_VAL_2        (GC_JG_VAL_2),
      .GC_JG_VAL_3        (GC_JG_VAL_3),
      .GC_JG_TH_0         (GC_JG_TH_0),
      .GC_JG_TH_1         (GC_JG_TH_1),
      .GC_JG_TH_2         (GC_JG_TH_2)
  ) u_axis_latency_gen (
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
      .m_axis_tready (m_axis_tready),

      // Delay and jitter controls
      .base_delay        (base_delay),
      .enable_base_delay (enable_base_delay),
      .enable_jitter     (enable_jitter),

      // FIFO occupancy
      .fifo_count (fifo_count)
  );

endmodule
