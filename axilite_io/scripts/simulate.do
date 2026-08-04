# axilite_io/simulate.do -- ModelSim/Questa simulation script
# Usage: vsim -do simulate.do
# or from the fpga-ip repo root: run axilite_io vhdl modelsim

onerror {abort}

# Compile VHDL packages and entity (VHDL-2008)
vlib work
vcom -2008  ../common/rtl/util_pkg.vhd
vcom -2008  ../axilite_io/rtl/axilite_io.vhd

# Compile VHDL wrapper and shared testbench
vcom -2008  ../axilite_io/tb/axilite_io_wrap.vhd
vcom -2008  ../axilite_io/tb/axilite_io_tb.vhd

# Elaborate (shared TB + VHDL wrapper)
vsim -voptargs=+acc work.axilite_io_tb

# Load waveform configuration
do ../axilite_io/scripts/wave.do

# Run for 200 clock cycles (2000 ns at 100 MHz)
run 2000ns

# Summary
echo "+++ SIMULATION COMPLETE +++"
} else {
    echo "!!! TESTS FAILED !!!"
}
