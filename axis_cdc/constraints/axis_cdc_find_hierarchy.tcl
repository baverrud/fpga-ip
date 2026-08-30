# Read-only Vivado helper for discovering synthesized axis_cdc cell names.
# Source this file after opening a synthesized or implemented design.
# It prints candidate Gray-pointer source and synchronizer-stage-0 cells.
# It does not create or modify any constraints.

set axis_cdc_discovery_patterns [list \
  wptr_source {.*r_s_reg\[wptr_gray\]\[[0-9]+\]$} \
  wptr_sync_stage_0 {.*wptr_gray_sync_chain_reg\[0\]\[[0-9]+\]$} \
  rptr_source {.*r_m_reg\[rptr_gray\]\[[0-9]+\]$} \
  rptr_sync_stage_0 {.*rptr_gray_sync_chain_reg\[0\]\[[0-9]+\]$}]

puts ""
puts "axis_cdc synthesized hierarchy candidates"
puts "========================================="
set axis_cdc_parent_paths [list]
foreach {endpoint_name endpoint_pattern} $axis_cdc_discovery_patterns {
  set endpoint_cells [lsort [get_cells -quiet -hierarchical -regexp $endpoint_pattern]]
  puts ""
  puts "$endpoint_name: [llength $endpoint_cells] cells"
  foreach endpoint_cell $endpoint_cells {
    puts "  $endpoint_cell"
    if {[regexp {^(.*)/(r_s_reg|r_m_reg|wptr_gray_sync_chain_reg|rptr_gray_sync_chain_reg)} \
        $endpoint_cell unused_match parent_path]} {
      lappend axis_cdc_parent_paths $parent_path
    }
  }
}
puts ""
puts "Unique candidate axis_cdc parent paths"
puts "--------------------------------------"
foreach parent_path [lsort -unique $axis_cdc_parent_paths] {
  puts "  $parent_path"
}
puts ""
puts "Group parent paths that use the same source and destination clocks."
puts "Use the full parent path in both the XDC and implementation hook."
