# ============================================================================
# wave.do -- Default Wave window setup for axis_fifo simulation
#
# Auto-loaded by sim_modelsim.do when ModelSim runs in GUI mode.
# Detects which testbench hierarchy is loaded (simple vs UVVM)
# and sets up the appropriate signal groups.
#
# Simple TB signals:
#   Clock & Reset, S_AXIS (write), M_AXIS (read), Status, DUT Internals
#
# UVVM TB signals:
#   Clock & Reset, FIFO Status, DUT ports via TH hierarchy,
#   DUT internals, TX/RX VVC transaction records
# ============================================================================

# Detect which testbench hierarchy is loaded
if {[llength [find signals -r /axis_fifo_uvvm_tb/*]] > 0} {
  # UVVM testbench
  set tb_path axis_fifo_uvvm_tb

  # Clear and set up UVVM waveform
  catch { delete wave * }

  # Clock & Reset
  add wave -divider "Clock & Reset"
  add wave -color yellow /$tb_path/aclk
  add wave /$tb_path/aresetn
  add wave /$tb_path/clock_ena

  # FIFO Status
  add wave -divider "FIFO Status"
  add wave -radix unsigned /$tb_path/fifo_count

  # DUT S_AXIS (Write) via TH hierarchy
  add wave -divider "DUT S_AXIS (Write)"
  add wave -radix hexadecimal /$tb_path/th_inst/s_axis_tdata
  add wave /$tb_path/th_inst/s_axis_tvalid
  add wave /$tb_path/th_inst/s_axis_tready

  # DUT M_AXIS (Read) via TH hierarchy
  add wave -divider "DUT M_AXIS (Read)"
  add wave -radix hexadecimal /$tb_path/th_inst/m_axis_tdata
  add wave /$tb_path/th_inst/m_axis_tvalid
  add wave /$tb_path/th_inst/m_axis_tready

  # DUT Internals
  add wave -divider "DUT Internal (r.*)"
  add wave /$tb_path/th_inst/dut/r

  # VVC Transaction Records
  add wave -divider "TX VVC (Instance 0)"
  add wave /$tb_path/th_inst/tx_if
  add wave -divider "RX VVC (Instance 1)"
  add wave /$tb_path/th_inst/rx_if
} else {
  # Simple testbench
  set tb_path axis_fifo_tb

  # Clear and set up simple waveform
  catch { delete wave * }

  # Clock & Reset
  add wave -divider "Clock & Reset"
  add wave -color yellow /$tb_path/aclk
  add wave /$tb_path/aresetn

  # Slave Interface (S_AXIS) - input side
  add wave -divider "Slave Interface (S_AXIS)"
  add wave -radix hexadecimal /$tb_path/s_axis_tdata
  add wave /$tb_path/s_axis_tvalid
  add wave /$tb_path/s_axis_tready

  # Master Interface (M_AXIS) - output side
  add wave -divider "Master Interface (M_AXIS)"
  add wave -radix hexadecimal /$tb_path/m_axis_tdata
  add wave /$tb_path/m_axis_tvalid
  add wave /$tb_path/m_axis_tready

  # FIFO Status
  add wave -divider "Status"
  add wave -radix unsigned /$tb_path/fifo_count

  # DUT Internals
  add wave -divider "DUT Internal (r.*)"
  add wave /$tb_path/dut/r
}

# Configure display
configure wave -signalnamewidth 2
configure wave -timelineunits ns
TreeUpdate

# Zoom to fit
wave zoom full
