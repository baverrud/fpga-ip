# =============================================================================
# sim.do — Thin wrapper delegating to sim_modelsim.do
# =============================================================================

set ip [file tail [file dirname [pwd]]]
if {![info exists files]} { set files "vhdl.f" }

# Auto-detect top entity from the [tb] section of the .f file
set tb ${ip}_tb
set flist_path [file normalize $files]
if {[file exists $flist_path]} {
  set fh [open $flist_path r]
  set in_tb 0
  while {[gets $fh line] >= 0} {
    set line [string trim $line]
    if {[regexp {\[tb\]} $line]} { set in_tb 1; continue }
    if {[regexp {\[.*\]} $line]}  { set in_tb 0 }
    if {$in_tb && $line ne "" && ![string match "#*" $line]} {
      # .f entries are relative to sub/fpga-ip/, resolve from repo root
      set repo_root [file normalize [file join [file dirname $flist_path] .. ..]]
      set tb_path [file normalize [file join $repo_root $line]]
      if {[file exists $tb_path]} {
        set tfh [open $tb_path r]
        while {[gets $tfh tline] >= 0} {
          if {[regexp {^\s*entity\s+(\w+)\s+is} $tline -> e]} {
            set tb $e; break
          }
        }
        close $tfh
      }
      break
    }
  }
  close $fh
}

do ../../common/scripts/sim_modelsim.do work.${tb} $files