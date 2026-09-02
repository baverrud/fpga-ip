# Vivado GUI Quick Start for axis_cdc Constraints

This is the minimum procedure for adding Gray-pointer constraints to a Vivado
GUI project. Read `AXIS_CDC_CONSTRAINTS.md` for explanations and adaptation.

## Files

Copy these two example files into your Vivado project directory and rename
them if desired:

- `axis_cdc_multi_instance_example.xdc`
- `axis_cdc_impl_hook_example.tcl`
- `axis_cdc_find_hierarchy.tcl` (optional, read-only discovery helper)

The example defaults directly match `zcu102_th_top`: 4 ns max delay and
2 ns bus skew. For another design, first update the timing values, clock
names, hierarchy expressions, tester count, and pointer width as described
in the detailed guide.

## Find the Hierarchical Names

Skip this section only when using the unmodified example with
`zcu102_th_top`.

1. In Vivado, select **Open Synthesized Design**.
2. Use **Tools -> Run Tcl Script** and select
   `axis_cdc_find_hierarchy.tcl`. The script is read-only.
3. If that menu is unavailable, enter this single Tcl Console command:

   ```tcl
   source <path>/axis_cdc_find_hierarchy.tcl
   ```

4. The script prints full synthesized names for the write/read Gray-pointer
   sources and synchronizer stage 0 destinations.
5. Group the printed names by their common parent path ending at each
   `axis_cdc` instance.
6. Put those stable parent paths into the XDC and hook regular expressions.
7. Set the hook tester count and per-bus pointer width to:

   ```text
   expected_tester_count = matching tester instances
   expected_pointer_width = log2(GC_CDC_DEPTH) + 1
   ```

See **Determine synthesized hierarchy** in `AXIS_CDC_CONSTRAINTS.md` for the
GUI Netlist method, regular-expression conversion, examples, and exact query
checks.

## Configure Vivado

1. Do not add the XDC as an automatically processed file in `constrs_1`.
   If it is already listed, right-click it, open **Source File Properties**,
   and clear **Used In Synthesis** and **Used In Implementation**. Keep the
   file on disk.
2. Add the hook Tcl file to **Utility Sources** so Vivado archives and tracks
   it with the project.
3. Open **Design Runs**.
4. Right-click `impl_1` and select **Change Run Settings**.
5. Expand `opt_design`.
6. Set **Pre Tcl Script** or **tcl.pre** to the copied hook file.
7. Apply the settings and save the project.
8. Right-click `impl_1`, select **Reset Run**, and reset implementation only.
9. Launch **Run Implementation**.

No Tcl Console commands are required for normal use. Vivado runs the hook
automatically before `opt_design`, after `link_design` has created the clocks
and synthesized hierarchy.

## Verify

Open the newest `impl_1` run log and search for `axis_cdc bus`.
The unmodified example first prints `clk_pl_0: 10.000 ns` and
`clk_pl_1: 4.000 ns`, then sixteen lines with
`source=4 sync=4 cells`, followed by:

```text
Applying axis_cdc constraints from ...
Parsing XDC File [...]
Finished Parsing XDC File [...]
Applied 16 axis_cdc bus-skew constraints at 2.000 ns
```

After implementation, open **Window -> Timing Constraints**, then inspect
**Exceptions -> Max Delay** and **Bus Skew**. Confirm:

| Group | Required delay |
|---|---:|
| Group A write pointer | 4 ns |
| Group A read pointer | 4 ns |
| Group B write pointer | 4 ns |
| Group B read pointer | 4 ns |

All max delays must be datapath-only. The Bus Skew view must contain sixteen
separate 2 ns constraints (four pointer buses per tester), all with
non-negative slack. The run log must not report `No cells matched`,
`No clocks matched`, or unsupported XDC commands for the example file.
