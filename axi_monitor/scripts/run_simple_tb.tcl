# ============================================================================
# run_simple_tb.tcl - Compile and run axi_monitor_simple_tb (VHDL-2008)
# ============================================================================
# Usage (from repo root sub/fpga-ip):
#   cmd.exe /c "vsim -c -do axi_monitor/scripts/run_simple_tb.tcl"
#
# The script CD's into axi_monitor/sim_simple/ so that the work library
# and modelsim.ini stay local to that folder (it's gitignored).
#
# NOTE: vlib creates a writable local modelsim.ini; do NOT use
#   "vmap work work" -- it would try to write to UVVM's read-only ini.
# ============================================================================

# CWD is <repo_root>/sub/fpga-ip
set repo_root [pwd]

# If any command errors (e.g. a vcom failure), quit immediately instead
# of dropping to the interactive ModelSim> prompt, which would otherwise
# make an automated run appear to hang until timeout.
onerror {quit -f}

# ---- Switch to sim_simple/ (gitignored build directory) ----
if {![file exists axi_monitor/sim_simple]} { file mkdir axi_monitor/sim_simple }
cd axi_monitor/sim_simple

# ---- Libraries (local work directory in sim_simple/) ----
if {[file exists work]} { vdel -all }
vlib work

# ---- Compile packages + shared IP (order matters) ----
vcom -2008 -quiet "$repo_root/common/rtl/util_pkg.vhd"
vcom -2008 -quiet "$repo_root/axis_fifo/rtl/axis_fifo.vhd"

# ---- Compile axi_monitor RTL ----
vcom -2008 -quiet "$repo_root/axi_monitor/rtl/axi_monitor_ar.vhd"
vcom -2008 -quiet "$repo_root/axi_monitor/rtl/axi_monitor_r.vhd"
vcom -2008 -quiet "$repo_root/axi_monitor/rtl/axi_monitor.vhd"

# ---- Compile TB support IP + testbench ----
vcom -2008 -quiet "$repo_root/parallel_prng/rtl/xorshift32.vhd"
vcom -2008 -quiet "$repo_root/parallel_prng/rtl/xorshift128.vhd"
vcom -2008 -quiet "$repo_root/jitter_gen/rtl/jitter_gen.vhd"
vcom -2008 -quiet "$repo_root/axis_latency_gen/rtl/axis_latency_gen.vhd"
vcom -2008 -quiet "$repo_root/axi_mem_model/rtl/axi_mem_model_core.vhd"
vcom -2008 -quiet "$repo_root/axi_mem_model/rtl/axi_mem_model.vhd"
vcom -2008 -quiet "$repo_root/axi_monitor/rtl/axi_ar_gen.vhd"
vcom -2008 -quiet "$repo_root/axi_monitor/tb/axi_monitor_simple_tb.vhd"

# ---- Run ----
vsim -voptargs="+acc" work.axi_monitor_simple_tb
run -all
quit -f
