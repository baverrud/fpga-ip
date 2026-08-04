//-----------------------------------------------------------------------
//Filename         : axis_skid_buffer.sv
//Description      : AXI4-Stream Skid Buffer with:
//                 :  - Two-stage pipeline (pipeline register + skid
//                 :    register) for backpressure absorption.
//                 :  - Bypass path -- when no stall occurs, data flows
//                 :    pipeline-reg -> output with zero combinational
//                 :    delay beyond the register Q output.
//                 :  - Three-state FSM control (EMPTY / ONE / TWO) for
//                 :    cycle-accurate handshake management.
//                 :  - State encoding carries handshake outputs directly:
//                 :      state[1] = s_axis_tready
//                 :      state[0] = m_axis_tvalid
//                 :    Output pins are wired straight from state bits.
//                 :    No combinational cascade from upstream signals.
//                 :  - Ports conforming strictly to AMBA AXI4-Stream
//                 :    specifications.
//                 :  - Fully synchronous active-low reset logic (aresetn).
//Author           : Rune Baeverrud
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------

`timescale 1ns/1ps

module axis_skid_buffer #(
    parameter int GC_TDATA_WIDTH = 8
) (
    input  logic aclk,
    input  logic aresetn, // Synchronous reset, active low

    // Slave Interface (Input transaction payload)
    input  logic [GC_TDATA_WIDTH-1:0] s_axis_tdata,
    input  logic                      s_axis_tvalid,
    output logic                      s_axis_tready,

    // Master Interface (Output transaction payload)
    output logic [GC_TDATA_WIDTH-1:0] m_axis_tdata,
    output logic                      m_axis_tvalid,
    input  logic                      m_axis_tready
);

  // -------------------------------------------------------------------
  // FSM state encoding
  //   state[1] -> s_axis_tready
  //   state[0] -> m_axis_tvalid
  // -------------------------------------------------------------------
  typedef enum logic [1:0] {
    EMPTY  = 2'b10,  // ready=1, valid=0
    ONE    = 2'b11,  // ready=1, valid=1
    TWO    = 2'b01   // ready=0, valid=1
  } state_t;

  // -------------------------------------------------------------------
  // State record
  // -------------------------------------------------------------------
  typedef struct {
    state_t                          state;
    logic [GC_TDATA_WIDTH-1:0]       pipe_data;
    logic [GC_TDATA_WIDTH-1:0]       skid_data;
  } t_rec;

  // Reset / default values
  const t_rec C_REC_DEFAULT = '{
    state:     EMPTY,
    pipe_data: {GC_TDATA_WIDTH{1'b0}},
    skid_data: {GC_TDATA_WIDTH{1'b0}}
  };

  // Current state and next-state signals
  t_rec r    = C_REC_DEFAULT;
  t_rec r_in;

  // -------------------------------------------------------------------
  // Output mapping
  // -------------------------------------------------------------------
  assign s_axis_tready = r.state[1];
  assign m_axis_tvalid = r.state[0];
  assign m_axis_tdata  = r.pipe_data;

  // -------------------------------------------------------------------
  // Combinational process -- next-state logic
  // -------------------------------------------------------------------
  always_comb begin
    t_rec v;
    v = r;

    unique case (r.state)
      EMPTY: begin
        if (s_axis_tvalid) begin
          v.pipe_data = s_axis_tdata;
          v.state     = ONE;
        end
      end

      ONE: begin
        if (m_axis_tready) begin
          // Downstream accepted the output
          if (s_axis_tvalid) begin
            // New data arrives in the same cycle -- reload pipeline
            v.pipe_data = s_axis_tdata;
            // State stays ONE
          end else begin
            // No new data -- pipeline drains
            v.state = EMPTY;
          end
        end else begin
          // Downstream stalls
          if (s_axis_tvalid) begin
            // Capture current pipeline data into skid register
            v.skid_data = r.pipe_data;
            // Accept new data into pipeline
            v.pipe_data = s_axis_tdata;
            v.state     = TWO;
          end
          // If no new data, hold state ONE (pipeline unchanged)
        end
      end

      TWO: begin
        if (m_axis_tready) begin
          // Downstream accepted -- shift skid into pipeline
          v.pipe_data = r.skid_data;
          v.state     = ONE;
        end
      end
    endcase

    r_in = v;
  end

  // -------------------------------------------------------------------
  // Registered process -- state update
  // -------------------------------------------------------------------
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      r <= C_REC_DEFAULT;
    end else begin
      r <= r_in;
    end
  end

endmodule
