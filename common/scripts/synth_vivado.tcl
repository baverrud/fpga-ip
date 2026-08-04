# ============================================================================
# synth_vivado.tcl -- Generic Vivado batch synthesis (Non-Project Mode)
#
# This script runs a full non-project synthesis flow. It is invoked by
# synthesize.bat/sh (via run.bat/run.sh) for headless batch builds.
# Uses files_util.tcl to parse section-filtered .f file lists.
#
# Workflow:
#   1. Parse arguments (top entity, file list, optional part number)
#   2. Set target part (default: xc7a35tftg256-1)
#   3. Parse .f file list for [rtl], [top], and [default] sections
#   4. Read all source files (VHDL-93/2008/2019, SystemVerilog)
#   5. Run synth_design
#   6. Write utilization.rpt and timing.rpt reports
#
# Arguments:
#   argv 0: Top-level entity name (e.g. axis_fifo_top)
#   argv 1: File list path (.f) -- only [rtl], [top], [default] sections
#   argv 2: (Optional) Target part number (default: xc7a35tftg256-1)
#
# Examples:
#   vivado -mode batch -source synth_vivado.tcl \
#     -tclargs axis_fifo_top ../scripts/vhdl.f
#   vivado -mode batch -source synth_vivado.tcl \
#     -tclargs axis_fifo_top ../scripts/sv.f xc7k70tfbv676-1
# ============================================================================

if { $argc < 2 } {
  puts "\[synth.tcl\] ERROR: Missing parameters!"
  puts "Usage: vivado -mode batch -source synth.tcl -tclargs <top_entity> <files_list_path> <optional_part>"
  exit 1
}

set TOP_ENTITY [lindex $argv 0]
set FILE_LIST [lindex $argv 1]

set PART_NUMBER "xc7a35tftg256-1"
if { $argc > 2 } {
  set PART_NUMBER [lindex $argv 2]
}

# Validate the target part before use; set_part fails silently on unknown parts.
if { [llength [get_parts -quiet $PART_NUMBER]] == 0 } {
  puts "\[synth.tcl\] ERROR: Unknown target part '$PART_NUMBER'."
  puts "\[synth.tcl\] Check the part number or install the required device family."
  exit 1
}

# Apply target device constraints
puts "\[synth.tcl\] Setting target part $PART_NUMBER..."
set_part $PART_NUMBER

# Source shared file list parser
source [file dirname [info script]]/files_util.tcl

# Define requested compile sections (RTL and top wrapper only)
# Bypassing tb sections avoids compile errors from missing external libs
set SECTIONS [list "rtl" "top" "default"]

# Load design dependencies
puts "\[synth.tcl\] Compiling design dependencies from $FILE_LIST (Sections: $SECTIONS)..."
set entries [parse_files_list $FILE_LIST $SECTIONS]
foreach entry $entries {
  lassign $entry file_path file_type vhdl_std

  if {$file_type == "sv"} {
    puts "\[synth.tcl\] Reading SystemVerilog file: $file_path"
    read_verilog -sv $file_path
  } elseif {$file_type == "vhd"} {
    switch [vhdl_std_normalize $vhdl_std] {
      "93" {
        puts "\[synth.tcl\] Reading VHDL-93 file: $file_path"
        read_vhdl $file_path
      }
      "2019" {
        puts "\[synth.tcl\] Reading VHDL-2019 file: $file_path"
        read_vhdl -vhdl2019 $file_path
      }
      default {
        puts "\[synth.tcl\] Reading VHDL-2008 file: $file_path"
        read_vhdl -vhdl2008 $file_path
      }
    }
  }
}

# Run Out-Of-Context synthesis
puts "\[synth.tcl\] Commencing core synthesis of top entity '$TOP_ENTITY'..."
synth_design -top $TOP_ENTITY -part $PART_NUMBER

# Generate performance and logic consumption report metrics
puts "\[synth.tcl\] Done! Saving utilization & timing properties inside vivado/ workspace..."
report_utilization -file utilization.rpt
report_timing -file timing.rpt

puts "\[synth.tcl\] Non-project synthesis flow checking completed successfully."
