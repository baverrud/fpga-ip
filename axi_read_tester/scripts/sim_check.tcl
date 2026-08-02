# sim_check.tcl - Compile and run axi_read_tester_tb.
if {[file exists work]} { vdel -all }
vlib work

set root "../.."

vcom -2008 -quiet "$root/common/rtl/util_pkg.vhd"
vcom -2008 -quiet "$root/axis_fifo/rtl/axis_fifo.vhd"
vcom -2008 -quiet "$root/parallel_prng/rtl/xorshift32.vhd"
vcom -2008 -quiet "$root/parallel_prng/rtl/xorshift128.vhd"
vcom -2008 -quiet "$root/jitter_gen/rtl/jitter_gen.vhd"
vcom -2008 -quiet "$root/axis_latency_gen/rtl/axis_latency_gen.vhd"
vcom -2008 -quiet "$root/axi_mem_model/rtl/axi_mem_model_core.vhd"
vcom -2008 -quiet "$root/axi_mem_model/rtl/axi_mem_model.vhd"
vcom -2008 -quiet "$root/axi_read_tester/rtl/axi_read_tester_ar_gen.vhd"
vcom -2008 -quiet "$root/axi_read_tester/rtl/axi_read_tester_r_mon.vhd"
vcom -2008 -quiet "$root/axi_read_tester/rtl/axi_read_tester.vhd"
vcom -2008 -quiet "$root/axi_read_tester/tb/axi_read_tester_tb.vhd"

puts "\n=== Compile complete ===\n"

vsim -voptargs="+acc" work.axi_read_tester_tb -c -do "
  set NumericStdNoWarnings 1;
  run -all;
  set NumericStdNoWarnings 0;
  quit -f
"
