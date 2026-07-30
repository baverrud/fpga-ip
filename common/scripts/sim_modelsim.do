# ============================================================================
# sim_modelsim.do — Generic ModelSim/Questa compile & run engine
#
# This script is the core simulation engine shared by all IP blocks. It is
# invoked by simulate.bat/sh via the unified run.bat/run.sh launcher.
#
# Workflow:
#   1. Parse arguments (top entity, file list, optional time resolution)
#   2. Source files_util.tcl and auto-detect UVVM from the shared .f metadata
#   3. Create a clean work library
#   4. Compile all files from the .f list (supports .vhd, .vhdl, .sv)
#   5. Elaborate and load the design (with +acc for full visibility)
#   6. In GUI mode: auto-load wave.do if present, run simulation, zoom
#   7. In batch mode: run simulation and exit
#
# Arguments:
#   $1: Top-level module/entity (e.g. work.axis_fifo_tb)
#   $2: File list path (.f) — sections [rtl], [tb], [top] all compiled
#   $3: (Optional) Simulator time resolution (e.g. "fs" for -t fs)
#
# File list format (.f):
#   Lines starting with # are ignored.
#   Section headers like "# [rtl]" are ignored (simulation compiles all).
#   Each data line: <relative_path> [vhdl_std]
#     vhdl_std can be: 93, 2008, 2019 (default: 2008)
#
# Examples:
#   vsim -c -do "do sim_modelsim.do work.axis_fifo_tb ../scripts/vhdl.f"
#   vsim -do "do sim_modelsim.do work.axis_fifo_uvvm_tb ../scripts/uvvm.f fs"
# ============================================================================

# Suppress benign Tcl/Tk background errors in GUI mode (e.g. Intel FPGA
# Starter Edition missing SrcCommon::LoadDBSDialog).
set PrefMain(EnableDB) 0
catch { set PrefMain(EnableDB) 0 }

# Ensure local modelsim.ini from the launcher has correct write permissions
if {[file exists modelsim.ini]} {
  catch { file attributes modelsim.ini -readonly 0 }
}

# In batch mode, Tcl/tool errors must terminate the simulator with a failing
# exit code. Otherwise vsim -c can drop to the "ModelSim>" prompt, which makes
# launcher flows like "run all" appear hung. Do not override onbreak here:
# UVVM testbenches often end via std.env.stop, which ModelSim reports as a
# break before returning control to the do-file.
if {[batch_mode]} {
  onerror {quit -code 1}
}

set TB_TOP ""
set FILE_LIST ""
set TIMING_RES ""
if {![info exists CREATE_PROJECT]} { set CREATE_PROJECT "" }

if {[info exists 1]} { set TB_TOP $1 }
if {[info exists 2]} { set FILE_LIST $2 }
if {[info exists 3]} { 
  if {$3 in {project 1 yes}} { set CREATE_PROJECT 1 } else { set TIMING_RES $3 }
}
if {[info exists 4]} { 
  if {$4 in {project 1 yes}} { set CREATE_PROJECT 1 }
}

# Fallback via argv
if {$TB_TOP == ""} {
  if {[info exists argv] && $argc > 0} {
    set first_arg [lindex $argv 0]
    if {[string index $first_arg 0] != "-"} {
      set TB_TOP $first_arg
      if {$argc > 1} { set FILE_LIST [lindex $argv 1] }
      if {$argc > 2} { 
        set val [lindex $argv 2]
        if {$val in {project 1 yes}} { set CREATE_PROJECT 1 } else { set TIMING_RES $val }
      }
      if {$argc > 3} { 
        set val [lindex $argv 3]
        if {$val in {project 1 yes}} { set CREATE_PROJECT 1 }
      }
    }
  }
}

# Normalize project flag
if {$CREATE_PROJECT in {project 1 yes}} { set CREATE_PROJECT 1 } else { set CREATE_PROJECT 0 }

if {$TB_TOP == "" || $FILE_LIST == ""} {
  puts "\[sim.do\] ERROR: Missing parameters!"
  puts "Usage: vsim -do \"do sim_modelsim.do <top_tb_name> <files_list_path> <optional_time_res>\""
  if {[batch_mode]} {
    quit -code 1
  }
  return
}

# In ModelSim do-file execution, [info script] resolves inside the simulator
# install tree (e.g. C:/mtitcl/vsim) rather than to this repository file.
# The .f file path is stable and absolute, so anchor shared helpers from there.
set FILE_LIST_DIR [file dirname $FILE_LIST]
source [file normalize [file join $FILE_LIST_DIR .. .. common scripts files_util.tcl]]

# --- Auto-detect top entity from [tb] section if TB_TOP ends with _AUTO_ ---
# When the caller passes a placeholder entity like <ip>_AUTO_, this block
# reads the .f file's [tb] section, opens that VHDL file, and extracts
# the actual entity name. This allows thin wrappers like sim.do to pass
# a dummy entity and let the .f file define the real one.
if {[string match "*_AUTO_" $TB_TOP]} {
  set entries [parse_files_list $FILE_LIST [list]]
  set repo_root [file dirname $FILE_LIST_DIR]
  foreach entry $entries {
    lassign $entry file_path file_type vhdl_std
    # Check if this file is in the [tb] section by reading the .f file
    # (The section info is lost in parse_files_list, so re-scan.)
  }
  # Fallback: scan .f for [tb] entry manually
  set fh [open $FILE_LIST r]
  set in_tb 0
  while {[gets $fh line] >= 0} {
    set line [string trim $line]
    if {[regexp {\[tb\]} $line]} { set in_tb 1; continue }
    if {[regexp {\[.*\]} $line]} { set in_tb 0 }
    if {$in_tb && $line ne "" && ![string match "#*" $line]} {
      set tb_rel [lindex $line 0]
      set tb_abs [file normalize [file join $repo_root $tb_rel]]
      if {[file exists $tb_abs]} {
        set tfh [open $tb_abs r]
        while {[gets $tfh tline] >= 0} {
          if {[regexp {^\s*entity\s+(\w+)\s+is} $tline -> e]} {
            set TB_TOP "work.$e"
            close $tfh
            break
          }
        }
        catch { close $tfh }
      }
      break
    }
  }
  close $fh
  puts "\[sim.do\] Auto-detected top entity: $TB_TOP"
}

# Auto-detect UVVM configuration via the shared .f utility.
set is_uvvm [is_uvvm_files_list $FILE_LIST]
# Also keep filename-based check for backwards compatibility
set basename [file rootname [file tail $FILE_LIST]]
if {!$is_uvvm && ([string match "*-uvvm" $basename] || [string equal "uvvm" $basename])} {
  set is_uvvm 1
}

if {$is_uvvm} {
  # UVVM top entity: if the parsed entity ends with _th (harness), use
  # the corresponding _tb (sequencer) as the top-level to simulate.
  # The harness has unconstrained ports that can only resolve when
  # instantiated inside the sequencer.
  if {[string match "*_th" $TB_TOP]} {
    set TB_TOP "[string range $TB_TOP 0 end-3]_tb"
  } elseif {![string match "*_uvvm_tb" $TB_TOP]} {
    regsub {_tb$} $TB_TOP {_uvvm_tb} TB_TOP
  }
  if {$TIMING_RES == ""} { set TIMING_RES "fs" }
  puts "\[sim.do\] Auto-detected UVVM configuration (TOP=$TB_TOP, TIME=$TIMING_RES)"
}

# Start from a clean library each time
if {[file exists work]} {
  catch { vdel -all work }
}
vlib work

# Compile all files from the list (ignoring comments and section headers)
proc compile_files_from_list {file_list_path} {
  set entries [parse_files_list $file_list_path [list]]
  foreach entry $entries {
    lassign $entry file_path file_type vhdl_std

    if {$file_type == "sv"} {
      puts "\[sim.do\] Commencing SystemVerilog compilation: $file_path"
      vlog -work work $file_path
    } elseif {$file_type == "vhd"} {
      switch [vhdl_std_normalize $vhdl_std] {
        "93" {
          puts "\[sim.do\] Commencing VHDL-93 compilation: $file_path"
          vcom -93 -work work $file_path
        }
        "2019" {
          puts "\[sim.do\] Commencing VHDL-2019 compilation: $file_path"
          vcom -2019 -work work $file_path
        }
        default {
          puts "\[sim.do\] Commencing VHDL-2008 compilation: $file_path"
          vcom -2008 -work work $file_path
        }
      }
    }
  }
}

puts "\[sim.do\] Compiling design dependencies from $FILE_LIST..."
compile_files_from_list $FILE_LIST

# --- Create ModelSim project (.mpf) if requested ---
# We use ModelSim's native project commands to create and populate the project.
#
# Project artifacts go into modelsim_proj/ (separate from modelsim/) so
# project and non-project runs coexist without clobbering each other.
# We name the project file after the IP directory name (e.g. axis_latency_gen.mpf)
# instead of the testbench entity name, avoiding namespace collisions.
if {$CREATE_PROJECT} {
  set ip_dir [file dirname [file dirname [file normalize $FILE_LIST]]]
  set ip_name [file tail $ip_dir]
  set proj_name $ip_name
  set proj_file "${proj_name}.mpf"
  set cr_file  "${proj_name}.cr.mti"
  set ::simdo_project_file [file normalize $proj_file]
  puts "\[sim.do\] Creating ModelSim project: $proj_file (IP: $ip_name)"

  set entries [parse_files_list $FILE_LIST [list]]

  # Build the project natively using ModelSim Tcl commands.
  # MODELSIM is cleared and modelsim.ini is copied locally so
  # project new / project addfile work without save errors.
  if {[catch {
    project new . $proj_name
    foreach entry $entries {
      lassign $entry file_path file_type vhdl_std
      set abs_path [file normalize $file_path]
      set native_path [file nativename $abs_path]
      project addfile $native_path
    }
    project close
    puts "\[sim.do\] ModelSim project created successfully."
  } err]} {
    puts "\[sim.do\] ERROR: Failed to create ModelSim project: $err"
  }

  # Fix VHDL standard in the .mpf to match our direct compiles.
  # Questa 2025.3 defaults to VHDL-2019 on project new; the RTL and TB
  # files use VHDL-2008. The project auto-compile on open uses whatever
  # is in the .mpf, so change it before opening.
  set mpf_fix_fh [open $proj_file r]
  set mpf_fix_data [read $mpf_fix_fh]
  close $mpf_fix_fh
  regsub -all {VHDL93 = \d+} $mpf_fix_data {VHDL93 = 2008} mpf_fix_data
  regsub -all {vhdl_use93 \d+} $mpf_fix_data {vhdl_use93 2008} mpf_fix_data
  set mpf_fix_fh [open $proj_file w]
  puts -nonewline $mpf_fix_fh $mpf_fix_data
  close $mpf_fix_fh

  # In GUI mode, open the newly-created project natively BEFORE loading the
  # design. ModelSim forbids opening a project while a simulation is active,
  # so this must happen first.
  if {![batch_mode]} {
    if {[catch {
      project open [file normalize $proj_file]
      puts "\[sim.do\] Project opened in GUI: $proj_file"
    } err]} {
      puts "\[sim.do\] NOTE: Could not auto-open project: $err"
    }
    # Compile through the project so the Project pane shows files as
    # compiled (green). No simulation is loaded yet, so the .mpf save
    # during compileall works cleanly.
    if {[catch {
      project compileall
      puts "\[sim.do\] Project sources compiled (Project pane status updated)."
    } err]} {
      puts "\[sim.do\] NOTE: project compileall reported: $err"
    }
  }
}

# Prepare loading arguments
set VSIM_ARGS "-voptargs=\"+acc\""
if {$TIMING_RES != ""} {
  set VSIM_ARGS "$VSIM_ARGS -t $TIMING_RES"
}

# Load simulator database
puts "\[sim.do\] Loading architecture top: $TB_TOP with arguments: $VSIM_ARGS"
eval vsim $VSIM_ARGS $TB_TOP

# Suppress ModelSim Intel FPGA Starter Edition database browser dialog bug.
# The free/Starter Edition lacks SrcCommon::LoadDBSDialog which the GUI
# tries to invoke on wave refresh. Disabling the DB preference avoids this.
# Apply unconditionally — the async Tk after script can fire even in -c mode.
catch { set PrefMain(EnableDB) 0 }

# Setup Wave configuration if we are in GUI mode and custom wave macro script exists
if {![batch_mode]} {
  # Run a custom wave setup if defined under scripts/ or tb/
  if {[file exists "../scripts/wave.do"]} {
    puts "\[sim.do\] Found custom wave.do configuration layout under IP scripts directory. Loading wave..."
    do ../scripts/wave.do
  } elseif {[file exists "../tb/wave.do"]} {
    puts "\[sim.do\] Found custom wave.do configuration layout under IP tb directory. Loading wave..."
    do ../tb/wave.do
  } else {
    # Default fallback: add all top-level signals recursively
    puts "\[sim.do\] No custom wave config layout discovered. Loading default waves..."
    catch { delete wave * }
    add wave -divider "Default System Waves"
    add wave /*
  }
  
  # Execute testbench run and zoom fit.
  # Wrap in catch to avoid GUI-mode Tcl errors after simulation ends
  # (e.g. ModelSim Intel FPGA Starter Edition wave refresh glitches).
  catch { run -all }
  catch { wave zoom full }

  # In project mode, install wrappers so Compile All uses -n (skip .mpf
  # save while simulation is loaded) and quit unloads the sim before
  # closing the project.
  if {$CREATE_PROJECT} {
    catch { rename quit _simdo_real_quit }
    catch { rename project _simdo_real_project }

    proc project {args} {
      set subcmd [lindex $args 0]
      if {$subcmd eq "compileall" && [lsearch -exact $args "-n"] < 0} {
        set args [linsert $args 1 -n]
      }
      uplevel 1 [linsert $args 0 _simdo_real_project]
    }

    proc quit {args} {
      if {[info exists ::simdo_project_file]} {
        catch { file attributes $::simdo_project_file -readonly 1 }
      }
      catch { _simdo_real_quit -sim }
      if {[info exists ::simdo_project_file]} {
        catch { file attributes $::simdo_project_file -readonly 0 }
      }
      catch { _simdo_real_project close }
      eval _simdo_real_quit $args
    }
  }
} else {
  # Batch CLI mode: execute tests and exit simulation workspace cleanly.
  # Wrap in catch to suppress the async SrcCommon::LoadDBSDialog Tk error
  # that can fire after simulation ends even in -c (batch) mode.
  catch { run -all }
  quit -code 0
}

