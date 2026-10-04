# axi_ar_mux standalone implementation timing check at 200 MHz.
#
# Usage, from a dedicated build directory (for example
# axi_ar_mux/.runs/vivado/implementation):
#
#   vivado -mode batch -source <fpga-ip>/axi_ar_mux/scripts/axi_ar_mux_implementation.tcl
#
# Runs synthesis, place and route of the VHDL wrapper and fails (exit 1) unless
# the routed worst setup slack is non-negative. Reports are written to
# ./reports. The larger xc7a200tfbg676-1 package is used only because the
# wrapper has more I/O ports than xc7a35tftg256-1 can place.

proc run_flow {} {
  set script_dir [file dirname [file normalize [info script]]]
  set ip_root    [file normalize [file join $script_dir .. ..]]
  set part       xc7a200tfbg676-1
  set report_dir [file normalize [file join [pwd] reports]]
  file mkdir $report_dir

  puts "AXI_AR_MUX_IMPLEMENTATION_PART=$part"
  puts "AXI_AR_MUX_IMPLEMENTATION_PERIOD_NS=5.000"

  read_vhdl -vhdl2008 [file join $ip_root common rtl util_pkg.vhd]
  read_vhdl -vhdl2008 [file join $ip_root axi_ar_mux rtl axi_ar_mux.vhd]
  read_vhdl -vhdl2008 [file join $ip_root axi_ar_mux top axi_ar_mux_top.vhd]
  read_xdc [file join $script_dir axi_ar_mux_timing.xdc]

  synth_design -top axi_ar_mux_top -part $part -flatten_hierarchy rebuilt
  opt_design
  place_design -directive ExtraPostPlacementOpt
  phys_opt_design -directive AggressiveExplore
  route_design -directive Explore

  report_utilization -file [file join $report_dir utilization.rpt]
  report_timing_summary -delay_type max -max_paths 20 \
    -file [file join $report_dir timing_summary.rpt]
  report_timing -delay_type max -max_paths 20 \
    -file [file join $report_dir timing_paths.rpt]
  check_timing -verbose -file [file join $report_dir check_timing.rpt]

  set timing_paths [get_timing_paths -delay_type max -max_paths 1]
  if {[llength $timing_paths] == 0} {
    error "no routed setup timing path was returned"
  }
  set wns [get_property SLACK [lindex $timing_paths 0]]
  puts "AXI_AR_MUX_POST_ROUTE_WNS_NS=$wns"
  if {$wns < 0.0} {
    error "axi_ar_mux misses the 5.0 ns setup requirement: WNS=$wns ns"
  }
  puts "AXI_AR_MUX_TIMING_CHECK=PASS"
}

if {[catch {run_flow} err]} {
  puts "AXI_AR_MUX_TIMING_CHECK=FAIL"
  puts "ERROR: $err"
  exit 1
}
exit 0
