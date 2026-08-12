# ============================================================================
# axi_ar_mux.xdc -- standalone timing self-check for the synthesis top.
#
# Creates the verified clock (143 MHz) used by the README performance claim
# so the run.py Vivado flow reports timing (WNS) against it. The exact-credit
# arbitration loop closes at 7.0 ns after full place & route (see README);
# the previous 200 MHz / 5.0 ns target failed by -1.37 ns. This is a
# verification-only constraint for the standalone flow; integration designs
# supply their own clocks and do NOT include this file (the core has no
# internal clock domains, so no CDC constraints are needed).
#
# Author           : Rune Baeverrud
# ============================================================================
create_clock -name aclk -period 7.000 -waveform {0.000 3.500} [get_ports aclk]
