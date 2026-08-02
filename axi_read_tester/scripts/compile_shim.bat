@echo off
REM Compile the VHDL-2019 AXI4 shim and its testbench.
REM Run from a CMD shell initialized with q26.
cd /d "%~dp0.."
vlib work
vcom -2019 -work work ../../common/rtl/axi4_pkg.vhd
if errorlevel 1 exit /b
vcom -2019 -work work ../../common/rtl/axilite_pkg.vhd
if errorlevel 1 exit /b
vcom -2019 -work work ../common/rtl/util_pkg.vhd
if errorlevel 1 exit /b
vcom -2019 -work work ../axis_fifo/rtl/axis_fifo.vhd
if errorlevel 1 exit /b
vcom -2019 -work work ../parallel_prng/rtl/xorshift32.vhd
if errorlevel 1 exit /b
vcom -2019 -work work ../parallel_prng/rtl/xorshift128.vhd
if errorlevel 1 exit /b
vcom -2019 -work work ../jitter_gen/rtl/jitter_gen.vhd
if errorlevel 1 exit /b
vcom -2019 -work work ../axis_latency_gen/rtl/axis_latency_gen.vhd
if errorlevel 1 exit /b
vcom -2019 -work work ../axi_mem_model/rtl/axi_mem_model_core.vhd
if errorlevel 1 exit /b
vcom -2019 -work work ../axi_mem_model/rtl/axi_mem_model.vhd
if errorlevel 1 exit /b
vcom -2019 -work work ../axilite_io/rtl/axilite_io.vhd
if errorlevel 1 exit /b
vcom -2019 -work work rtl/axi_read_tester_ar_gen.vhd
if errorlevel 1 exit /b
vcom -2019 -work work rtl/axi_read_tester_r_mon.vhd
if errorlevel 1 exit /b
vcom -2019 -work work rtl/axi_read_tester.vhd
if errorlevel 1 exit /b
vcom -2019 -work work rtl/axi4_read_tester_shim.vhd
if errorlevel 1 exit /b
vcom -2019 -work work rtl/axi4_read_tester_shim_top.vhd
if errorlevel 1 exit /b
vcom -2019 -work work tb/axi4_read_tester_shim_tb.vhd
if errorlevel 1 exit /b
echo === All compiled successfully ===
