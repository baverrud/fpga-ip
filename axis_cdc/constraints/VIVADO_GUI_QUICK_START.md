# Vivado GUI Quick Start for axis_cdc Constraints

This is the minimum procedure for adding Gray-pointer constraints to a Vivado
GUI project. Read `AXIS_CDC_CONSTRAINTS.md` for explanations and adaptation.

## Files

Copy these two example files into your Vivado project directory and rename
them if desired:

- `axis_cdc_multi_instance_example.xdc`
- `axis_cdc_impl_hook_example.tcl`
- `axis_cdc_find_hierarchy.tcl` (optional, read-only discovery helper)

The example defaults directly match `zcu102_th_top`. For another design,
first update the clock names, hierarchy expressions, and expected endpoint
count as described in the detailed guide.

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
7. Set the hook endpoint count to:

   ```text
   matching instances * (log2(GC_CDC_DEPTH) + 1)
   ```

See **Determine synthesized hierarchy** in `AXIS_CDC_CONSTRAINTS.md` for the
GUI Netlist method, regular-expression conversion, examples, and exact query
checks.

## Configure Vivado

1. Do not add the XDC as an automatically processed file in `constrs_1`.
   If it is already listed, right-click it, open **Source File Properties**,
   and clear **Used In Synthesis** and **Used In Implementation**. Keep the
   file on disk.
2. Open **Design Runs**.
3. Right-click `impl_1` and select **Change Run Settings**.
4. Expand `opt_design`.
5. Set **Pre Tcl Script** or **tcl.pre** to the copied hook file.
6. Apply the settings and save the project.
7. Right-click `impl_1`, select **Reset Run**, and reset implementation only.
8. Launch **Run Implementation**.

No Tcl Console commands are required for normal use. Vivado runs the hook
automatically before `opt_design`, after `link_design` has created the clocks
and synthesized hierarchy.

## Verify

Open the newest `impl_1` run log and search for `axis_cdc endpoint`.
The unmodified example should print eight endpoint lines with `16 cells` each,
followed by:

```text
Applying axis_cdc constraints from ...
Parsing XDC File [...]
Finished Parsing XDC File [...]
```

After implementation, open **Window -> Timing Constraints**, then inspect
**Exceptions -> Max Delay**. Confirm four logical groups:

| Group | Required delay |
|---|---:|
| Group A write pointer | 10 ns |
| Group A read pointer | 4 ns |
| Group B write pointer | 4 ns |
| Group B read pointer | 10 ns |

All must show datapath-only max-delay constraints. The run log must not report
`No cells matched`, `No clocks matched`, or unsupported XDC commands for the
example file.
