# ============================================================================
# axis_cdc_multi_instance_example.xdc
#
# Worked Vivado example for a design containing two groups of axis_cdc
# instances with opposite stream directions. The default values match the
# zcu102_th_top example:
#
#   Group A: gen_tester[*].tester/u_bridge/u_ar_cdc
#     s_axis_aclk = clk_pl_0 (10 ns)
#     m_axis_aclk = clk_pl_1 (4 ns)
#
#   Group B: gen_tester[*].tester/u_bridge/u_r_cdc
#     s_axis_aclk = clk_pl_1 (4 ns)
#     m_axis_aclk = clk_pl_0 (10 ns)
#
# To adapt this example, update:
#   1. clk_pl_0 and clk_pl_1 to the clock-object names in report_clocks.
#   2. The hierarchy before r_s_reg/r_m_reg and the synchronizer registers.
#   3. The implementation hook endpoint patterns and expected cell count.
#
# Read this XDC after link_design. The companion example hook does this at
# the opt_design pre-hook. Do not load it automatically before link_design.
# See AXIS_CDC_CONSTRAINTS.md for full explanations and
# VIVADO_GUI_QUICK_START.md for the minimum GUI procedure.
# ============================================================================

# Group A write pointer: source clock clk_pl_0 -> destination clk_pl_1.
set_max_delay -datapath_only \
  -from [get_cells -hierarchical -regexp {.*gen_tester\[[0-9]+\]\.tester/u_bridge/u_ar_cdc/r_s_reg\[wptr_gray\]\[[0-9]+\]$}] \
  -to [get_cells -hierarchical -regexp {.*gen_tester\[[0-9]+\]\.tester/u_bridge/u_ar_cdc/wptr_gray_sync_chain_reg\[0\]\[[0-9]+\]$}] \
  [get_property PERIOD [get_clocks clk_pl_0]]

# Group A read pointer: source clock clk_pl_1 -> destination clk_pl_0.
set_max_delay -datapath_only \
  -from [get_cells -hierarchical -regexp {.*gen_tester\[[0-9]+\]\.tester/u_bridge/u_ar_cdc/r_m_reg\[rptr_gray\]\[[0-9]+\]$}] \
  -to [get_cells -hierarchical -regexp {.*gen_tester\[[0-9]+\]\.tester/u_bridge/u_ar_cdc/rptr_gray_sync_chain_reg\[0\]\[[0-9]+\]$}] \
  [get_property PERIOD [get_clocks clk_pl_1]]

# Group B write pointer: source clock clk_pl_1 -> destination clk_pl_0.
set_max_delay -datapath_only \
  -from [get_cells -hierarchical -regexp {.*gen_tester\[[0-9]+\]\.tester/u_bridge/u_r_cdc/r_s_reg\[wptr_gray\]\[[0-9]+\]$}] \
  -to [get_cells -hierarchical -regexp {.*gen_tester\[[0-9]+\]\.tester/u_bridge/u_r_cdc/wptr_gray_sync_chain_reg\[0\]\[[0-9]+\]$}] \
  [get_property PERIOD [get_clocks clk_pl_1]]

# Group B read pointer: source clock clk_pl_0 -> destination clk_pl_1.
set_max_delay -datapath_only \
  -from [get_cells -hierarchical -regexp {.*gen_tester\[[0-9]+\]\.tester/u_bridge/u_r_cdc/r_m_reg\[rptr_gray\]\[[0-9]+\]$}] \
  -to [get_cells -hierarchical -regexp {.*gen_tester\[[0-9]+\]\.tester/u_bridge/u_r_cdc/rptr_gray_sync_chain_reg\[0\]\[[0-9]+\]$}] \
  [get_property PERIOD [get_clocks clk_pl_0]]

# Do not apply set_false_path or set_clock_groups -asynchronous over these
# pointer paths. Either exception can override the max-delay constraints.
