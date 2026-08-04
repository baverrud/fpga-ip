# ============================================================================
# files_util.tcl -- Shared .f file list parsing and UVVM detection utilities
#
# Used by synth_vivado.tcl, synth_vivado_project.tcl, and sim_modelsim.do.
#
# Section-filtering:
#   The .f files use section headers like:
#     # [rtl]    -- RTL source files (compiled by all flows)
#     # [top]    -- Top-level wrapper (synthesis only)
#     # [tb]     -- Testbench files (simulation only)
#   Each caller requests only the sections it needs.
#
# Returns: list of {file_path file_type vhdl_std} triples
#   file_type: "sv" for .sv, "vhd" for .vhd/.vhdl
#   vhdl_std:  optional VHDL standard suffix ("93", "2008", "2019") or ""
# ============================================================================

# ----------------------------------------------------------------------------
# is_uvvm_files_list -- Check whether a .f file's [tb] entries reference UVVM
#
# Usage:   set result [is_uvvm_files_list <file_list_path>]
# Returns: 1 if any file listed in the [tb] section contains
#          "uvvm_vvc_framework", else 0
#
# The detection keyword "uvvm_vvc_framework" is the UVVM VVC framework library
# that all UVVM VVC-based testbenches must reference via:
#   library uvvm_vvc_framework;
#
# Note: This function intentionally does NOT check for "library uvvm_util"
# because that would trigger the ModelSim top-entity rename (_tb -> _uvvm_tb)
# for testbenches that use uvvm_util but have a plain _tb entity name.
# The uvvm_util-only detection lives in detect_uvvm.bat/sh for XSim skip purposes.
# ----------------------------------------------------------------------------
proc is_uvvm_files_list {file_list_path} {
  set file_list_dir [file dirname $file_list_path]

  if {[catch {open $file_list_path r} fp] != 0} {
    return 0
  }

  set file_data [read $fp]
  close $fp
  set in_tb_section 0

  foreach line [split $file_data "\n"] {
    set line [string trim $line]
    if {$line == ""} { continue }

    if {[string index $line 0] == "#"} {
      set stripped [string trim [string range $line 1 end]]
      if {$stripped != "" && [string index $stripped 0] == "\[" && [string index $stripped end] == "\]"} {
        set section [string tolower [string range $stripped 1 [expr {[string length $stripped] - 2}]]]
        set in_tb_section [expr {$section eq "tb"}]
      }
      continue
    }

    if {$in_tb_section} {
      set tokens [regexp -all -inline {\S+} $line]
      set tb_file [lindex $tokens 0]
      set tb_path [file join $file_list_dir .. $tb_file]

      if {[catch {open $tb_path r} tbfp] == 0} {
        set tb_data [read $tbfp]
        close $tbfp
        # Match only "uvvm_vvc_framework" (VVC-based UVVM). This drives ModelSim's
        # top-entity rename (_tb -> _uvvm_tb). The util-only "library uvvm_util"
        # check lives in detect_uvvm.bat/sh for XSim skip purposes, not here.
        if {[string match -nocase "*uvvm_vvc_framework*" $tb_data]} {
          return 1
        }
      }
    }
  }

  return 0
}

# ----------------------------------------------------------------------------
# vhdl_std_normalize -- Map an optional .f VHDL standard suffix to a canonical
# bucket used by all synthesis/simulation flows.
#
# Usage:   set std [vhdl_std_normalize <suffix>]
# Returns: "93"   for 93/2000/2002 (pre-2008 dialects read as classic VHDL)
#          "2019" for 2019
#          "2008" for anything else (default, including empty)
#
# Callers apply the tool-specific action themselves (e.g. read_vhdl flag or
# set_property file_type), so only the classification lives here.
# ----------------------------------------------------------------------------
proc vhdl_std_normalize {vhdl_std} {
  switch -- $vhdl_std {
    "93" - "2000" - "2002" { return "93" }
    "2019"                 { return "2019" }
    default                { return "2008" }
  }
}

# ----------------------------------------------------------------------------

# Parse a .f file list and return entries matching the requested sections.
#
# Arguments:
#   file_list_path    - Path to the .f file
#   required_sections - List of section names to include (e.g., {rtl top})
#                       Pass an empty list to include all file entries.
#
# Returns a list of {file_path file_type vhdl_std} triples.
#
# file_type is "sv" for .sv files, "vhd" for .vhd/.vhdl files.
# vhdl_std is the optional standard suffix (e.g., "93", "2008", "2019") or "".
proc parse_files_list {file_list_path required_sections} {
  set fp [open $file_list_path r]
  set file_data [read $fp]
  close $fp

  # Standardize active sections to lower-case list
  set active_sections [list]
  foreach s $required_sections {
    lappend active_sections [string tolower $s]
  }
  set include_all_sections [expr {[llength $active_sections] == 0}]

  set current_section "default"
  set result [list]

  set lines [split $file_data "\n"]
  foreach line $lines {
    set line [string trim $line]
    if {$line == ""} { continue }

    # Detect header tags (e.g. # [rtl], # [top])
    if {[string index $line 0] == "#"} {
      set stripped [string trim [string range $line 1 end]]
      if {[string index $stripped 0] == "\[" && [string index $stripped end] == "\]"} {
        set current_section [string tolower [string range $stripped 1 [expr {[string length $stripped] - 2}]]]
      }
      continue
    }

    # Process only if part of our active sections, or everything if the
    # caller requested an empty section list.
    if {$include_all_sections || [lsearch -exact $active_sections $current_section] >= 0} {
      set tokens [regexp -all -inline {\S+} $line]
      set file_path [lindex $tokens 0]
      set file_path "../../$file_path"

      set vhdl_std ""
      if {[llength $tokens] > 1} {
        set vhdl_std [string tolower [lindex $tokens 1]]
      }

      set ext [file extension $file_path]
      if {$ext == ".sv"} {
        lappend result [list $file_path "sv" ""]
      } elseif {$ext == ".vhdl" || $ext == ".vhd"} {
        lappend result [list $file_path "vhd" $vhdl_std]
      }
    }
  }

  return $result
}
