# =============================================================================
# sim.do -- Thin wrapper delegating to sim_modelsim.do
# =============================================================================

set ip [file tail [file dirname [pwd]]]
if {![info exists files]} { set files "vhdl.f" }
do ../../common/scripts/sim_modelsim.do work.${ip}_AUTO_ $files