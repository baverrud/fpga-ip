# ============================================================================
# run_ar_gen_simple_tb.tcl - Compile and run axi_ar_gen_simple_tb
# ============================================================================
# Usage (from repo root sub/fpga-ip):
#   cmd.exe /c "vsim -c -do axi_monitor/scripts/run_ar_gen_simple_tb.tcl"
#
# Minimal chain for the standalone axi_ar_gen TB:  util_pkg + xorshift128
# (the PRNG axi_ar_gen instantiates) + axi_ar_gen + the TB.
#
# The script CD's into axi_monitor/sim_ar_gen/ so that the work library
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

# ---- Switch to sim_ar_gen/ (gitignored build directory) ----
if {![file exists axi_monitor/sim_ar_gen]} { file mkdir axi_monitor/sim_ar_gen }
cd axi_monitor/sim_ar_gen

# ---- Libraries (local work directory in sim_ar_gen/) ----
if {[file exists work]} { vdel -all }
vlib work

# ---- Compile packages + support IP (order matters) ----
vcom -2008 -quiet "$repo_root/common/rtl/util_pkg.vhd"
vcom -2008 -quiet "$repo_root/parallel_prng/rtl/xorshift128.vhd"

# ---- Compile axi_monitor RTL (axi_ar_gen only) ----
vcom -2008 -quiet "$repo_root/axi_monitor/rtl/axi_ar_gen.vhd"

# ---- Compile testbench ----
vcom -2008 -quiet "$repo_root/axi_monitor/tb/axi_ar_gen_simple_tb.vhd"

# ---- Run ----
vsim -voptargs="+acc" work.axi_ar_gen_simple_tb
run -all
quit -f
