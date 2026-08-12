# ============================================================================
# axi_r_demux.xdc -- standalone timing self-check for the synthesis top.
#
# Creates the 250 MHz clock used by the README performance claim so the
# run.py Vivado flow reports timing (WNS) against it. This is a
# verification-only constraint for the standalone flow; integration designs
# supply their own clocks and do NOT include this file (the core has no
# internal clock domains, so no CDC constraints are needed).
#
# Author           : Rune Baeverrud
# ============================================================================
create_clock -name aclk -period 4.000 -waveform {0.000 2.000} [get_ports aclk]
