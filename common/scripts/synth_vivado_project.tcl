# ============================================================================
# synth_vivado_project.tcl — Generic Vivado project maker (Project Mode)
#
# This script creates a Vivado project from a .f file list. It is invoked
# by synthesize.bat/sh (via run.bat/run.sh) with the "gui" flag.
# The resulting project is suitable for both synthesis and GUI simulation
# (sources are properly split into Design and Simulation filesets).
# Uses files_util.tcl to parse section-filtered .f file lists.
#
# Workflow:
#   1. Parse arguments (top entity, file list, optional project name, part)
#   2. Close any open project
#   3. Create a new project with -force (overwrites existing)
#   4. Parse .f file list: [rtl], [top] → Design Sources; [tb] → Simulation Sources
#   5. Add source files with correct file types per section
#   6. Set the top-level entity
#
# Arguments:
#   argv 0: Top-level entity name (e.g. axis_fifo_top)
#   argv 1: File list path (.f) — only [rtl], [top], [default] sections
#   argv 2: (Optional) Project name (default: <top>_proj)
#   argv 3: (Optional) Target part number (default: xc7a35tftg256-1)
#
# Examples:
#   vivado -mode batch -source synth_vivado_project.tcl \
#     -tclargs axis_fifo_top ../scripts/vhdl.f
#   vivado -mode batch -source synth_vivado_project.tcl \
#     -tclargs axis_fifo_top ../scripts/sv.f my_project xc7k70tfbv676-1
# ============================================================================

if { $argc < 2 } {
  puts "\[project.tcl\] ERROR: Missing parameters!"
  puts "Usage: vivado -mode batch -source project.tcl -tclargs <top_entity> <files_list_path> <optional_proj_name> <optional_part>"
  exit 1
}

set TOP_ENTITY [lindex $argv 0]
set FILE_LIST [lindex $argv 1]

set PROJ_NAME "${TOP_ENTITY}_proj"
if { $argc > 2 } {
  set PROJ_NAME [lindex $argv 2]
}

set PART_NUMBER "xc7a35tftg256-1"
if { $argc > 3 } {
  set PART_NUMBER [lindex $argv 3]
}

# Validate the target part before use; create_project fails silently on unknown parts.
if { [llength [get_parts -quiet $PART_NUMBER]] == 0 } {
  puts "\[project.tcl\] ERROR: Unknown target part '$PART_NUMBER'."
  puts "\[project.tcl\] Check the part number or install the required device family."
  exit 1
}

# Close any active open project
catch { close_project }

# Create project, overwrite database if it sits on disk
puts "\[project.tcl\] Instantiating project database '$PROJ_NAME' under part '$PART_NUMBER'..."
create_project -force $PROJ_NAME ./$PROJ_NAME -part $PART_NUMBER

# Source shared file list parser
source [file dirname [info script]]/files_util.tcl

# Define requested compile sections. Rtl/top go to Design Sources,
# tb files go to Simulation Sources.
set DESIGN_SECTIONS [list "rtl" "top" "default"]
set SIM_SECTIONS [list "tb"]

# Helper: add files from parsed entries to a target fileset
proc add_files_to_project {entries target_fileset} {
  set fs [get_filesets -quiet $target_fileset]
  if {$fs eq ""} {
    if {$target_fileset eq "sim_1"} {
      set fs [create_fileset -simset sim_1]
    } else {
      set fs [get_filesets sources_1]
    }
  }
  foreach entry $entries {
    lassign $entry file_path file_type vhdl_std

    set file_obj [add_files -norecurse -fileset $fs $file_path]

    if {$file_type == "sv"} {
      puts "  + SystemVerilog: $file_path"
      set_property file_type "SystemVerilog" $file_obj
    } elseif {$file_type == "vhd"} {
      switch [vhdl_std_normalize $vhdl_std] {
        "93" {
          puts "  + VHDL-93: $file_path"
          set_property file_type "VHDL" $file_obj
        }
        "2019" {
          puts "  + VHDL-2019: $file_path"
          set_property file_type "VHDL 2019" $file_obj
        }
        default {
          puts "  + VHDL-2008: $file_path"
          set_property file_type "VHDL 2008" $file_obj
        }
      }
    }
  }
}

# Add design sources (rtl, top)
puts "\[project.tcl\] Adding Design Sources from '$FILE_LIST' (Sections: $DESIGN_SECTIONS)..."
set design_entries [parse_files_list $FILE_LIST $DESIGN_SECTIONS]
add_files_to_project $design_entries "sources_1"

# Add simulation sources (tb)
puts "\[project.tcl\] Adding Simulation Sources from '$FILE_LIST' (Sections: $SIM_SECTIONS)..."
set sim_entries [parse_files_list $FILE_LIST $SIM_SECTIONS]
add_files_to_project $sim_entries "sim_1"

# Set project properties and hierarchy context
set_property "top" $TOP_ENTITY [get_filesets sources_1]

puts "\[project.tcl\] Project '$PROJ_NAME' created cleanly!"
