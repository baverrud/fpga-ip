# ============================================================================
# axi_read_tester.xdc -- standalone timing self-check for the synthesis top.
#
# Creates a 100 MHz (10.0 ns) clock on the client domain and a 250 MHz
# (4.0 ns) clock on the memory domain so the run.py Vivado flow reports
# timing (WNS) against them.
# This is a verification-only constraint for the standalone flow; integration
# designs supply their own clocks and do NOT include this file.
#
# Author           : Rune Baeverrud
# ============================================================================
create_clock -name aclk     -period 10.000 -waveform {0.000 5.000} [get_ports aclk]
create_clock -name mem_aclk -period 4.000  -waveform {0.000 2.000} [get_ports mem_aclk]
