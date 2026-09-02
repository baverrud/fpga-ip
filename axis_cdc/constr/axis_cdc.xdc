# ============================================================================
# axis_cdc.xdc -- Vivado timing constraints template
#
# PURPOSE
#   The axis_cdc is a clock-domain-crossing (CDC) module. Its
#   safety depends on the implementation tool honoring the constraints
#   below: the Gray-pointer bus is bounded into the receiving clock
#   domain. Without this bound, different Gray bits can have different
#   flight times and the destination can observe more than one bit
#   changing at once. That would invalidate the FIFO safety argument.
#
# NOTE ON THE DATA PATH
#   Data crosses through a dual-port RAM (write port in the source
#   domain, read port in the destination domain), so there is no direct
#   cross-domain data path to constrain. Only the Gray pointers cross the
#   boundary. The pointer bus delay constraints below ensure that a
#   receiving edge cannot observe bits from two different Gray transitions.
#
# PER-INSTANCE TEMPLATE - READ BEFORE USE
#   Constraint files cannot be used unchanged:
#   (1) The default 4 ns max delay and 2 ns bus skew match the committed
#       ZCU102 integration. Update both values if another design needs a
#       different physical bound.
#   (2) The cell paths assume the module instance is labelled 'u_core'
#       and that Vivado kept the RTL register names. After
#       implementation, verify the paths (get_cells -hier) and adjust
#       the hierarchy prefix for your instantiation.
#   (3) This file is an integration template. Apply it from the top-level
#       Vivado project after clocks and the implemented hierarchy exist.
#   For non-Vivado tools, express the same constraints in SDC.
#   See VIVADO_GUI_QUICK_START.md for minimal setup and
#   AXIS_CDC_CONSTRAINTS.md for detailed explanations and a worked example.
#
# Author           : Rune Baeverrud
# Licensing        : Zero-Clause BSD (0BSD)
# ============================================================================

# ----------------------------------------------------------------------------
# 1. Gray-pointer bus delay and skew: write pointer into the destination
#    domain. The max delay is the fastest involved clock period (4 ns in
#    the committed integration). Bus skew is constrained to 2 ns.
#
#    Do NOT add set_clock_groups -asynchronous or set_false_path over
#    these same paths. Those exceptions take precedence and would disable
#    the max-delay check. The max-delay exception intentionally provides
#    the CDC timing treatment without requiring phase alignment.
# ----------------------------------------------------------------------------
set_max_delay -datapath_only \
  -from [get_cells -hierarchical -regexp {.*u_core/r_s_reg\[wptr_gray\]\[[0-9]+\]$}] \
  -to [get_cells -hierarchical -regexp {.*u_core/wptr_gray_sync_chain_reg\[0\]\[[0-9]+\]$}] \
  4.000

set_bus_skew \
  -from [get_cells -hierarchical -regexp {.*u_core/r_s_reg\[wptr_gray\]\[[0-9]+\]$}] \
  -to [get_cells -hierarchical -regexp {.*u_core/wptr_gray_sync_chain_reg\[0\]\[[0-9]+\]$}] \
  2.000

# ----------------------------------------------------------------------------
# 2. Gray-pointer bus delay and skew: read pointer into the source domain.
#    Update the hierarchy and synthesized names as required.
# ----------------------------------------------------------------------------
set_max_delay -datapath_only \
  -from [get_cells -hierarchical -regexp {.*u_core/r_m_reg\[rptr_gray\]\[[0-9]+\]$}] \
  -to [get_cells -hierarchical -regexp {.*u_core/rptr_gray_sync_chain_reg\[0\]\[[0-9]+\]$}] \
  4.000

set_bus_skew \
  -from [get_cells -hierarchical -regexp {.*u_core/r_m_reg\[rptr_gray\]\[[0-9]+\]$}] \
  -to [get_cells -hierarchical -regexp {.*u_core/rptr_gray_sync_chain_reg\[0\]\[[0-9]+\]$}] \
  2.000

# ----------------------------------------------------------------------------
# 3. Synchronizer implementation requirements.
#    The first stage is deliberately timed by the max-delay constraints
#    above. The paths between synchronizer stages remain normally timed;
#    ASYNC_REG in the RTL keeps those stages physically close together.
#    Verify both max-delay and bus-skew constraints with report_exceptions,
#    report_timing, and report_bus_skew in the implemented design.
# ----------------------------------------------------------------------------
