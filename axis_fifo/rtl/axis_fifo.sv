//-----------------------------------------------------------------------
//Filename         : axis_fifo.sv
//Description      : Safe, Parameterizable Elastic Buffer (FBEB) translated to SystemVerilog:
//                 :  - Inferring of shift-register LUTs (SRLs, on Xilinx 
//                 :    architectures) for depths > 2, or a double-buffer 
//                 :    if GC_FIFO_DEPTH = 2.
//                 :  - Simulation address-guarding for non-power-of-2 depths.
//                 :  - Unsigned occupancy level count output port (fifo_count).
//                 :  - Fully registered handshaking flow-control.
//                 :  - 100% combinational timing isolation between upstream and 
//                 :    downstream transaction domains (maximum Fmax).
//                 :  - Ports conforming strictly to AMBA AXI4-Stream specifications.
//                 :  - Fully synchronous active-low reset logic (aresetn).
//Author           : Rune Baeverrud (Translated to SystemVerilog)
//Current Revision : 1.00
//Licensing        : Zero-Clause BSD (0BSD)
//-----------------------------------------------------------------------

`timescale 1ns/1ps

module axis_fifo #(
    parameter int GC_TDATA_WIDTH = 8,
    parameter int GC_FIFO_DEPTH  = 3
) (
    input  logic aclk,
    input  logic aresetn, // Synchronous reset, active low
    
    // Slave Interface (Input transaction payload)
    input  logic [GC_TDATA_WIDTH-1:0] s_axis_tdata,
    input  logic s_axis_tvalid,
    output logic s_axis_tready,

    // Master Interface (Output transaction payload)
    output logic [GC_TDATA_WIDTH-1:0] m_axis_tdata,
    output logic m_axis_tvalid,
    input  logic m_axis_tready,

    // FIFO occupancy level
    output logic [$clog2(GC_FIFO_DEPTH):0] fifo_count
);

  localparam int INDEX_WIDTH = $clog2(GC_FIFO_DEPTH) + 1;
  localparam logic signed [INDEX_WIDTH-1:0] RESET_INDEX = -1;

  // State record equivalent struct definition
  typedef struct {
    logic [GC_TDATA_WIDTH-1:0] fifo_data [0:GC_FIFO_DEPTH-1];
    logic signed [INDEX_WIDTH-1:0] fifo_index;
    logic s_axis_tready;
    logic m_axis_tvalid;
  } t_rec;

  // Set the clean initial/reset model constant matching C_REC_DEFAULT in VHDL.
  // We use don't-cares ('x) on 'fifo_data' to explicitly let the synthesis compiler
  // skip routing reset networks to the array, which guarantees SRL inference.
  const t_rec C_REC_DEFAULT = '{
    fifo_data: '{default: 'x},
    fifo_index: RESET_INDEX,
    s_axis_tready: 1'b1,
    m_axis_tvalid: 1'b0
  };

  t_rec r = C_REC_DEFAULT;    // Current state record registers with default initial values
  t_rec r_in;                 // Next state transition logic signals

  int read_index;

  // Safe address decoding to prevent out-of-range simulator crashes
  always_comb begin
    if (r.fifo_index < 0) begin
      read_index = 0;
    end else begin
      read_index = int'(r.fifo_index);
    end
  end

  // Drive outputs combinatorially from registered state
  // Explicitly casting the math expression to unsigned using standard system operations
  // conforms to strict design-rule checkers while avoiding dynamic size mismatches
  assign fifo_count    = $unsigned(r.fifo_index + 1);
  assign m_axis_tdata  = r.fifo_data[read_index];
  assign s_axis_tready = r.s_axis_tready;
  assign m_axis_tvalid = r.m_axis_tvalid;

  // Main Logic (Two-Process FSM / Register-Transfer style)
  always_comb begin
    // Recover stored state values into internal variable
    t_rec v;
    v = r;

    // --- Write and Shift Interface ---
    if (s_axis_tvalid && r.s_axis_tready) begin
      // Shift array forward
      for (int i = GC_FIFO_DEPTH - 1; i > 0; i = i - 1) begin
        v.fifo_data[i] = v.fifo_data[i-1];
      end
      v.fifo_data[0] = s_axis_tdata;

      // If pushing without popping (increasing occupancy level)
      if (!(m_axis_tready && r.m_axis_tvalid)) begin
        v.fifo_index = r.fifo_index + 1'b1;
      end
    end
    // --- Drain / Pop Interface ---
    else if (m_axis_tready && r.m_axis_tvalid) begin
      v.fifo_index = r.fifo_index - 1'b1;
    end

    // --- Flow-Control Handshaking Flags generation ---
    if (v.fifo_index == (GC_FIFO_DEPTH - 1)) begin
      v.s_axis_tready = 1'b0; // FIFO is full, hold incoming writes
    end else begin
      v.s_axis_tready = 1'b1;
    end

    if (v.fifo_index == RESET_INDEX) begin
      v.m_axis_tvalid = 1'b0; // FIFO is empty, no data available
    end else begin
      v.m_axis_tvalid = 1'b1;
    end

    // Store state
    r_in = v;
  end

  // State-Holding Register Update Process
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      r <= C_REC_DEFAULT;
    end else begin
      r <= r_in;
    end
  end

endmodule
