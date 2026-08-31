# Vivado implementation-hook example for axis_cdc constraints.
#
# The defaults match the companion multi-instance XDC and zcu102_th_top.
# For another design, update the clock names/periods, endpoint patterns,
# tester count, pointer width, and XDC timing values. See
# AXIS_CDC_CONSTRAINTS.md.

set script_dir [file dirname [file normalize [info script]]]
set cdc_xdc [file join $script_dir axis_cdc_multi_instance_example.xdc]

set expected_clock_periods [dict create clk_pl_0 10.000 clk_pl_1 4.000]
dict for {clock_name expected_period} $expected_clock_periods {
  set clock [get_clocks -quiet $clock_name]
  if {[llength $clock] != 1} {
    error "axis_cdc constraint clock not found: $clock_name"
  }
  set actual_period [get_property PERIOD $clock]
  puts "axis_cdc clock $clock_name: $actual_period ns"
  if {abs($actual_period - $expected_period) > 0.001} {
    error "axis_cdc clock $clock_name: expected $expected_period ns, found $actual_period ns"
  }
}

# Four tester instances, with four Gray-pointer bits per bus for
# GC_CDC_DEPTH = 8. Validate each logical bus separately because bus-skew
# constraints must not combine independent axis_cdc instances.
set expected_tester_count 4
set expected_pointer_width 4
set bus_skew_ns 2.000
set pointer_bus_patterns [list \
  ar_wptr \
    {.*gen_tester\[%d\]\.tester/u_bridge/u_ar_cdc/r_s_reg\[wptr_gray\]\[[0-9]+\]$} \
    {.*gen_tester\[%d\]\.tester/u_bridge/u_ar_cdc/wptr_gray_sync_chain_reg\[0\]\[[0-9]+\]$} \
  ar_rptr \
    {.*gen_tester\[%d\]\.tester/u_bridge/u_ar_cdc/r_m_reg\[rptr_gray\]\[[0-9]+\]$} \
    {.*gen_tester\[%d\]\.tester/u_bridge/u_ar_cdc/rptr_gray_sync_chain_reg\[0\]\[[0-9]+\]$} \
  r_wptr \
    {.*gen_tester\[%d\]\.tester/u_bridge/u_r_cdc/r_s_reg\[wptr_gray\]\[[0-9]+\]$} \
    {.*gen_tester\[%d\]\.tester/u_bridge/u_r_cdc/wptr_gray_sync_chain_reg\[0\]\[[0-9]+\]$} \
  r_rptr \
    {.*gen_tester\[%d\]\.tester/u_bridge/u_r_cdc/r_m_reg\[rptr_gray\]\[[0-9]+\]$} \
    {.*gen_tester\[%d\]\.tester/u_bridge/u_r_cdc/rptr_gray_sync_chain_reg\[0\]\[[0-9]+\]$}]

set validated_buses [list]
for {set tester_index 0} {$tester_index < $expected_tester_count} {incr tester_index} {
  foreach {bus_name source_template sync_template} $pointer_bus_patterns {
    set source_cells [get_cells -quiet -hierarchical -regexp \
      [format $source_template $tester_index]]
    set sync_cells [get_cells -quiet -hierarchical -regexp \
      [format $sync_template $tester_index]]
    set source_count [llength $source_cells]
    set sync_count [llength $sync_cells]
    puts "axis_cdc bus tester=$tester_index $bus_name: source=$source_count sync=$sync_count cells"
    if {($source_count != $expected_pointer_width) || ($sync_count != $expected_pointer_width)} {
      error "axis_cdc bus tester=$tester_index $bus_name: expected $expected_pointer_width source/sync cells, found $source_count/$sync_count"
    }
    lappend validated_buses [list $source_cells $sync_cells]
  }
}

puts "Applying axis_cdc constraints from $cdc_xdc"
read_xdc $cdc_xdc
foreach bus_endpoints $validated_buses {
  lassign $bus_endpoints source_cells sync_cells
  set_bus_skew -from $source_cells -to $sync_cells $bus_skew_ns
}
puts "Applied [expr {$expected_tester_count * 4}] axis_cdc bus-skew constraints at $bus_skew_ns ns"
