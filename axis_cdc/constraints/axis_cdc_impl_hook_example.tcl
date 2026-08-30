# Vivado implementation-hook example for axis_cdc constraints.
#
# The defaults match the companion multi-instance XDC and zcu102_th_top.
# For another design, update the clock names, endpoint patterns, and expected
# endpoint count. See AXIS_CDC_CONSTRAINTS.md.

set script_dir [file dirname [file normalize [info script]]]
set cdc_xdc [file join $script_dir axis_cdc_multi_instance_example.xdc]

foreach clock_name {clk_pl_0 clk_pl_1} {
  if {[llength [get_clocks -quiet $clock_name]] != 1} {
    error "axis_cdc constraint clock not found: $clock_name"
  }
}

# Four instances times four Gray-pointer bits for GC_CDC_DEPTH = 8.
set expected_endpoint_count 16
set endpoint_patterns [list \
  group_a_wptr_source {.*gen_tester\[[0-9]+\]\.tester/u_bridge/u_ar_cdc/r_s_reg\[wptr_gray\]\[[0-9]+\]$} \
  group_a_wptr_sync {.*gen_tester\[[0-9]+\]\.tester/u_bridge/u_ar_cdc/wptr_gray_sync_chain_reg\[0\]\[[0-9]+\]$} \
  group_a_rptr_source {.*gen_tester\[[0-9]+\]\.tester/u_bridge/u_ar_cdc/r_m_reg\[rptr_gray\]\[[0-9]+\]$} \
  group_a_rptr_sync {.*gen_tester\[[0-9]+\]\.tester/u_bridge/u_ar_cdc/rptr_gray_sync_chain_reg\[0\]\[[0-9]+\]$} \
  group_b_wptr_source {.*gen_tester\[[0-9]+\]\.tester/u_bridge/u_r_cdc/r_s_reg\[wptr_gray\]\[[0-9]+\]$} \
  group_b_wptr_sync {.*gen_tester\[[0-9]+\]\.tester/u_bridge/u_r_cdc/wptr_gray_sync_chain_reg\[0\]\[[0-9]+\]$} \
  group_b_rptr_source {.*gen_tester\[[0-9]+\]\.tester/u_bridge/u_r_cdc/r_m_reg\[rptr_gray\]\[[0-9]+\]$} \
  group_b_rptr_sync {.*gen_tester\[[0-9]+\]\.tester/u_bridge/u_r_cdc/rptr_gray_sync_chain_reg\[0\]\[[0-9]+\]$}]

foreach {endpoint_name endpoint_pattern} $endpoint_patterns {
  set endpoint_count [llength [get_cells -quiet -hierarchical -regexp $endpoint_pattern]]
  puts "axis_cdc endpoint $endpoint_name: $endpoint_count cells"
  if {$endpoint_count != $expected_endpoint_count} {
    error "axis_cdc endpoint $endpoint_name: expected $expected_endpoint_count cells, found $endpoint_count"
  }
}

puts "Applying axis_cdc constraints from $cdc_xdc"
read_xdc $cdc_xdc
