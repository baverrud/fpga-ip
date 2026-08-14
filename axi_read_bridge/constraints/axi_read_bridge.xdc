# ============================================================================
# axi_read_bridge.xdc -- default 100 MHz client / 250 MHz native clocks
#
# Author           : Rune Baeverrud
# ============================================================================
create_clock -name aclk -period 10.000 -waveform {0.000 5.000} [get_ports aclk]
create_clock -name mem_aclk -period 4.000 -waveform {0.000 2.000} [get_ports mem_aclk]
