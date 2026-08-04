# =============================================================================
# compile.do (Shared Master Script)
#
# Expects: ip (e.g. "axis_fifo"), files (e.g. "vhdl.f") set by wrapper.
# Derives all paths from CWD, which must be $repo_root/$ip/sim/<folder>/.
# =============================================================================

# --- Derive paths from CWD + ip + name ---
# CWD after wrapper's cd: .../sub/fpga-ip/<ip>/sim/<folder>/
set build_dir [pwd]
set ip_dir    [file dirname [file dirname $build_dir]]  ;# up to <ip>/
set repo_root [file dirname $ip_dir]                     ;# up to sub/fpga-ip/

if {![info exists std]}   { set std   "-2008"   }
if {![info exists tb]}    { set tb    "${ip}_tb" }
if {![info exists files]} { set files "vhdl.f"  }
set flist     "$repo_root/$ip/scripts/$files"
set work_dir  "$build_dir/work"
set wave_do   "$repo_root/$ip/scripts/wave01.do"

# --- Auto-detect top entity from [tb] section of .f file ---
# Overrides the default ${ip}_tb when the .f file references a
# differently-named testbench (e.g. a manual copy with a custom name).
set fh [open $flist]
set in_tb 0
while {[gets $fh line] >= 0} {
    set line [string trim $line]
    if {[regexp {\[tb\]} $line]} { set in_tb 1; continue }
    if {[regexp {\[.*\]} $line]}  { set in_tb 0 }
    if {$in_tb && $line ne "" && ![string match "#*" $line]} {
        set tb_path [file join $repo_root $line]
        if {[file exists $tb_path]} {
            set tfh [open $tb_path]
            while {[gets $tfh tline] >= 0} {
                if {[regexp {^\s*entity\s+(\w+)\s+is} [string trim $tline] -> e]} {
                    set tb $e; break
                }
            }
            close $tfh
        }
        break
    }
}
close $fh

# 1. Save wave layout from previous session, but only if a wave window
#    with signals exists (avoid overwriting saved layout with empty one).
if {![catch {wave signals}] && [llength [wave signals]] > 0} {
    write format wave $wave_do
}

# 2. Unload the active simulation to release file locks on the work folder
quit -sim

# 3. Create the work library. vlib handles modelsim.ini automatically;
#    no vmap needed (it would try to write to UVVM's read-only ini
#    pointed to by $MODELSIM -- see fpga-rules/questa_modelsim_guide.md).
file delete -force $work_dir
file mkdir [file dirname $work_dir]
vlib $work_dir

# 4. Compile VHDL and SystemVerilog files based on their extension
foreach f [split [read [open $flist]] \n] {
    set f [string trim $f]
    if {$f ne "" && ![string match "#*" $f] && ![string match "-*" $f]} {
        set path [file join $repo_root $f]
        if {[file extension $f] in {.vhd .vhdl}} {
            vcom $std -work work $path
        } elseif {[file extension $f] in {.v .sv}} {
            vlog -sv -work work $path
        }
    }
}

# 5. Relaunch simulation
vsim work.$tb

# 6. Apply wave format if it exists (GUI mode only)
if {![batch_mode] && [file exists $wave_do]} {
    view wave
    do $wave_do
}