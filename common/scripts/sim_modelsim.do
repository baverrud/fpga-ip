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

if {[info exists 1]} { set TB_TOP $1 }
if {[info exists 2]} { set FILE_LIST $2 }
if {[info exists 3]} { set TIMING_RES $3 }

# Fallback via argv
if {$TB_TOP == ""} {
  if {[info exists argv] && $argc > 0} {
    set first_arg [lindex $argv 0]
    if {[string index $first_arg 0] != "-"} {
      set TB_TOP $first_arg
      if {$argc > 1} { set FILE_LIST [lindex $argv 1] }
      if {$argc > 2} { set TIMING_RES [lindex $argv 2] }
    }
  }
}

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
} else {
  # Batch CLI mode: execute tests and exit simulation workspace cleanly.
  # Wrap in catch to suppress the async SrcCommon::LoadDBSDialog Tk error
  # that can fire after simulation ends even in -c (batch) mode.
  catch { run -all }
  quit -code 0
}
