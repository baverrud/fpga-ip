# =============================================================================
# sim.do -- Generic simulation wrapper (copy to any IP's scripts/)
# =============================================================================

set ip    [file tail [file dirname [pwd]]]
set files "vhdl.f"
set tb    "${ip}_tb"
set std   "-2008"

file mkdir ../sim/sim01
cd ../sim/sim01

do ../../../common/scripts/compile.do

run -all
if {![batch_mode]} { wave zoom full }
catch { write format wave $wave_do }

if {[batch_mode]} {
    quit -f
} else {
    rename quit _tcl_quit
    proc quit {args} {
        catch { write format wave $::wave_do }
        eval _tcl_quit $args
    }
}