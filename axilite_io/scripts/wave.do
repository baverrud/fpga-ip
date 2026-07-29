# axilite_io_tb wave.do - group signals by interface
onerror {resume}
quietly WaveActivateNextPane {} 0

add wave -noupdate -divider {Clock & Reset}
add wave -noupdate /axilite_io_tb/clk
add wave -noupdate /axilite_io_tb/rstn
add wave -noupdate /axilite_io_tb/test_done

add wave -noupdate -divider {AXI4-Lite}
add wave -noupdate -hexadecimal /axilite_io_tb/awaddr
add wave -noupdate /axilite_io_tb/awvalid
add wave -noupdate /axilite_io_tb/awready
add wave -noupdate -hexadecimal /axilite_io_tb/wdata
add wave -noupdate -hexadecimal /axilite_io_tb/wstrb
add wave -noupdate /axilite_io_tb/wvalid
add wave -noupdate /axilite_io_tb/wready
add wave -noupdate /axilite_io_tb/bready
add wave -noupdate /axilite_io_tb/bvalid
add wave -noupdate -hexadecimal /axilite_io_tb/bresp
add wave -noupdate -hexadecimal /axilite_io_tb/araddr
add wave -noupdate /axilite_io_tb/arvalid
add wave -noupdate /axilite_io_tb/arready
add wave -noupdate /axilite_io_tb/rready
add wave -noupdate /axilite_io_tb/rvalid
add wave -noupdate -hexadecimal /axilite_io_tb/rdata
add wave -noupdate -hexadecimal /axilite_io_tb/rresp

add wave -noupdate -divider {o_data / i_data}
add wave -noupdate -hexadecimal /axilite_io_tb/o_data
add wave -noupdate -hexadecimal /axilite_io_tb/i_data

add wave -noupdate -divider {AXI-Stream Master}
add wave -noupdate -hexadecimal /axilite_io_tb/m_axis_tdata
add wave -noupdate /axilite_io_tb/m_axis_tvalid

add wave -noupdate -divider {AXI-Stream Slave}
add wave -noupdate -hexadecimal /axilite_io_tb/s_axis_tdata
add wave -noupdate /axilite_io_tb/s_axis_tready

TreeUpdate [SetDefaultTree]
WaveRestoreZoom {0 ns} {1000 ns}
