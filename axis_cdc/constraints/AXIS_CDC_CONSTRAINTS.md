# Integrating axis_cdc Constraints in Vivado

## Purpose

`axis_cdc` is a Gray-pointer asynchronous FIFO. Payload data crosses through
a dual-port RAM. The write and read Gray pointers cross through synchronizer
chains.

The RTL marks both synchronizer arrays with `ASYNC_REG = TRUE`. This tells
Vivado to preserve and place synchronizer stages appropriately, but it does
not bound the routing delay of every bit in a Gray-pointer bus. Each Gray bus
also needs a `set_max_delay -datapath_only` constraint from its source pointer
registers to synchronizer stage 0.

The delay bound must equal the period of the clock that generates that
pointer. A Gray pointer can change once per source-clock cycle. Bounding all
bits to one source period prevents bits from consecutive pointer transitions
from overlapping at the receiver.

## Included Examples

| File | Purpose |
|---|---|
| `axis_cdc.xdc` | Minimal single-instance template. |
| `axis_cdc_multi_instance_example.xdc` | Worked multi-instance example. Defaults match `zcu102_th_top`. |
| `axis_cdc_impl_hook_example.tcl` | Implementation hook that validates clocks/endpoints and loads the worked XDC. |
| `axis_cdc_find_hierarchy.tcl` | Read-only helper that prints synthesized Gray-pointer cell names. |
| `VIVADO_GUI_QUICK_START.md` | Minimum GUI setup and verification procedure. |
| `AXIS_CDC_CONSTRAINTS.md` | This detailed integration and adaptation guide. |

The worked example can be used directly by the ZCU102 throughput project. It
uses these known values:

- `clk_pl_0`: 10 ns, tester/client clock.
- `clk_pl_1`: 4 ns, memory clock.
- Group A: `gen_tester[*].tester/u_bridge/u_ar_cdc`.
- Group B: `gen_tester[*].tester/u_bridge/u_r_cdc`.
- Four tester instances.
- `GC_CDC_DEPTH = 8`, giving four Gray-pointer bits.

For another design, adapt the example as described below.

## XDC Basics

XDC means Xilinx Design Constraints. An XDC file uses a constrained subset of
Tcl to describe timing and physical requirements. It does not create hardware.
It tells Vivado what the synthesized and implemented hardware must satisfy.

### Syntax used by the example

A line starting with `#` is a comment. A backslash at the end of a line
continues the command on the next line.

Square brackets execute a nested Tcl command and substitute its result:

```tcl
[get_clocks source_clock]
```

Braces preserve a regular expression as text:

```tcl
{.*u_axis_cdc/r_s_reg\[wptr_gray\]\[[0-9]+\]$}
```

`get_cells` selects synthesized cells such as flip-flops. `get_clocks`
selects timing-clock objects. An XDC command can parse successfully even when
these queries return no objects, so endpoint verification is mandatory.

## Anatomy of a Gray-Pointer Constraint

A write-pointer constraint has this shape:

```tcl
set_max_delay -datapath_only \
  -from [get_cells -hierarchical -regexp {<instance>/r_s_reg\[wptr_gray\]\[[0-9]+\]$}] \
  -to [get_cells -hierarchical -regexp {<instance>/wptr_gray_sync_chain_reg\[0\]\[[0-9]+\]$}] \
  [get_property PERIOD [get_clocks <source_clock>]]
```

- `set_max_delay` imposes an upper delay bound. It does not insert delay.
- `-datapath_only` constrains cell-to-cell data routing without requiring a
  synchronous phase relationship between the two clocks.
- `-from` selects the source-domain Gray-pointer registers.
- `-to` selects stage 0 of the destination-domain synchronizer.
- `get_property PERIOD` obtains the source-clock period automatically.
- `-hierarchical` searches below the top-level design.
- `-regexp` uses a regular expression to match generated hierarchy and bits.

The read pointer requires a second constraint:

```tcl
set_max_delay -datapath_only \
  -from [get_cells -hierarchical -regexp {<instance>/r_m_reg\[rptr_gray\]\[[0-9]+\]$}] \
  -to [get_cells -hierarchical -regexp {<instance>/rptr_gray_sync_chain_reg\[0\]\[[0-9]+\]$}] \
  [get_property PERIOD [get_clocks <destination_clock>]]
```

The read pointer is generated in the FIFO destination domain, so its source
clock is the `axis_cdc` `m_axis_aclk` clock.

## Regular-Expression Breakdown

The worked example includes this hierarchy expression:

```text
.*gen_tester\[[0-9]+\]\.tester/u_bridge/u_ar_cdc/
```

It is one line in the XDC. Its pieces mean:

| Expression | Meaning |
|---|---|
| `.*` | Allow any hierarchy prefix. |
| `gen_tester` | Match the VHDL generate label. |
| `\[` and `\]` | Match literal brackets in a synthesized name. |
| `[0-9]+` | Match one or more digits, allowing any generated tester index. |
| `\.` | Match the literal dot after the generate index. |
| `tester/u_bridge/u_ar_cdc/` | Match the tester, bridge, and CDC instance labels. |
| `$` | Require the match to end after the pointer bit index. |

Vivado synthesized names in the worked project look like:

```text
gen_tester[0].tester/u_bridge/u_ar_cdc/r_s_reg[wptr_gray][0]
gen_tester[0].tester/u_bridge/u_ar_cdc/wptr_gray_sync_chain_reg[0][0]
```

## Adapting the Example

### 1. Determine clock-object names

After opening a synthesized or implemented design, run **Report Clocks** from
the GUI. Record the Vivado clock-object names and periods that drive
`s_axis_aclk` and `m_axis_aclk`.

Replace `clk_pl_0` and `clk_pl_1` in both the XDC and hook. Do not create
additional clocks if a processing system, clock wizard, or another constraint
file already defines them.

### 2. Determine synthesized hierarchy

This is usually the hardest integration step. XDC constraints select cells in
the synthesized netlist, not VHDL source objects. Synthesis can add generated
indices, flatten levels, encode record fields, or rename registers. Do not
construct endpoint names only by reading the VHDL hierarchy.

Use **Open Synthesized Design** or **Open Implemented Design** first. Do not
use only **Open Elaborated Design**: elaboration shows the RTL hierarchy, but
the XDC must match the names retained after synthesis.

#### GUI method

1. In the Flow Navigator, select **Open Synthesized Design**. An implemented
  design is also suitable.
2. Open **Window -> Netlist** if the Netlist pane is hidden.
3. In the Netlist tree, expand the top-level instance toward the known
  `axis_cdc` instance. Start from labels visible in the VHDL, such as the
  bridge instance and then the CDC instance.
4. Expand the CDC instance and look for register cells containing these
  names:

  ```text
  r_s_reg[wptr_gray]
  wptr_gray_sync_chain_reg[0]
  r_m_reg[rptr_gray]
  rptr_gray_sync_chain_reg[0]
  ```

5. Select one bit of each register. Open **Window -> Properties** if needed.
  Record the complete hierarchical `NAME` property, including every parent
  level and generated index.
6. Repeat for every distinct `axis_cdc` hierarchy group. Instances that use
  opposite clock directions must be kept in separate constraint groups.

Vivado GUI versions differ in their Netlist search controls. If a **Find** or
binoculars button is available, set the object type to **Cells**, enable
hierarchical searching, and search for `wptr_gray` or `rptr_gray`. If the
search does not support partial names reliably, use the helper method below.

#### Read-only helper method

The included `axis_cdc_find_hierarchy.tcl` script removes most of the manual
tree expansion. It only queries and prints cells; it does not add, delete, or
change constraints.

1. Open a synthesized or implemented design in the Vivado GUI.
2. Use **Tools -> Run Tcl Script** if available and select
  `axis_cdc_find_hierarchy.tcl`.
3. If that menu is unavailable, enter this one command in the Tcl Console:

  ```tcl
  source <path>/axis_cdc_find_hierarchy.tcl
  ```

4. Read the printed lists in the Tcl Console. The script reports four
  categories:

  - `wptr_source`
  - `wptr_sync_stage_0`
  - `rptr_source`
  - `rptr_sync_stage_0`

Example output begins like this:

```text
wptr_source: 32 cells
  gen_tester[0].tester/u_bridge/u_ar_cdc/r_s_reg[wptr_gray][0]
  ...
wptr_sync_stage_0: 32 cells
  gen_tester[0].tester/u_bridge/u_ar_cdc/wptr_gray_sync_chain_reg[0][0]
  ...
```

The total may include several CDC groups. Group the names by the common
parent path ending at the CDC instance, for example:

```text
gen_tester[0].tester/u_bridge/u_ar_cdc
gen_tester[0].tester/u_bridge/u_r_cdc
```

The helper also prints a **Unique candidate axis_cdc parent paths** summary
after the endpoint lists, so these paths do not need to be extracted from the
full cell list manually. Group the summarized parent paths according to their
source and destination clocks before writing XDC expressions.

For every group, confirm that all four categories have the same number of
bits. A missing category means synthesis renamed or removed an expected
endpoint and the XDC must not be applied until the mismatch is understood.

#### Convert a printed name into a regular expression

Suppose the helper prints:

```text
gen_tester[0].tester/u_bridge/u_ar_cdc/r_s_reg[wptr_gray][0]
```

Convert it in small steps:

1. Keep the stable parent labels:

  ```text
  gen_tester[0].tester/u_bridge/u_ar_cdc/
  ```

2. Replace the generated tester number with a numeric pattern:

  ```text
  gen_tester[[0-9]+].tester/u_bridge/u_ar_cdc/
  ```

3. Escape characters that are special in a regular expression. Literal
  brackets become `\[` and `\]`; the literal dot becomes `\.`:

  ```text
  gen_tester\[[0-9]+\]\.tester/u_bridge/u_ar_cdc/
  ```

4. Add `.*` at the beginning if an optional hierarchy prefix is allowed.
5. Append the exact register suffix and `$` to require the name to end after
  the bit index:

  ```text
  .*gen_tester\[[0-9]+\]\.tester/u_bridge/u_ar_cdc/r_s_reg\[wptr_gray\]\[[0-9]+\]$
  ```

Do not replace every hierarchy level with `.*`. A very broad expression can
accidentally constrain unrelated CDC instances that use different clocks.
Keep enough parent labels to identify one clock-direction group uniquely.

#### Test the expression before using it

Paste one candidate query into the Tcl Console while the synthesized or
implemented design is open:

```tcl
get_cells -hierarchical -regexp \
  {.*gen_tester\[[0-9]+\]\.tester/u_bridge/u_ar_cdc/r_s_reg\[wptr_gray\]\[[0-9]+\]$}
```

Vivado should print the matching full cell names. Then count them:

```tcl
llength [get_cells -quiet -hierarchical -regexp \
  {.*gen_tester\[[0-9]+\]\.tester/u_bridge/u_ar_cdc/r_s_reg\[wptr_gray\]\[[0-9]+\]$}]
```

The expected count is:

```text
matching instances * (log2(GC_CDC_DEPTH) + 1)
```

Repeat the query and count for all four endpoint categories before putting
the expressions into the XDC and hook.

#### Names that must be confirmed

For each clock-direction group, confirm the full synthesized names of:

- The parent instance hierarchy.
- `r_s_reg[wptr_gray][*]`.
- `wptr_gray_sync_chain_reg[0][*]`.
- `r_m_reg[rptr_gray][*]`.
- `rptr_gray_sync_chain_reg[0][*]`.

Update the regular expressions in both the XDC and hook. The XDC applies the
constraints; the hook independently checks the same patterns before loading
it.

### 3. Calculate expected endpoint count

For a power-of-two FIFO depth:

```text
Gray pointer width = log2(GC_CDC_DEPTH) + 1
Expected count = matching axis_cdc instances * Gray pointer width
```

Examples:

| Instances | Depth | Pointer width | Expected endpoint count |
|---:|---:|---:|---:|
| 1 | 8 | 4 | 4 |
| 4 | 8 | 4 | 16 |
| 2 | 16 | 5 | 10 |

Set `expected_endpoint_count` in the hook accordingly. If two instance groups
contain different numbers of instances or different depths, give them
separate expected counts or separate hook checks.

### 4. Remove unused groups

A single `axis_cdc` instance needs only two constraints: write pointer and
read pointer. The worked file has four because the two groups use opposite
clock directions. Delete Group B if the design has no second group.

## Why an Implementation Hook Is Used

A hook is a Tcl script Vivado runs automatically before or after a selected
build step. `tcl.pre` runs before that step; `tcl.post` runs afterward.

The worked example uses the `opt_design` pre-hook:

```text
init_design
  -> link_design creates clocks and synthesized hierarchy
opt_design.tcl.pre
  -> validate clock and endpoint objects
  -> read the axis_cdc XDC
opt_design
place_design
route_design
```

This is robust for hierarchical constraints. A normal project constraint can
be read before `link_design`, when `get_cells` and generated clock objects do
not exist. The XDC may appear to load while matching no endpoints.

The hook contains procedural Tcl checks (`foreach`, `if`, and `error`). These
commands belong in the Tcl hook, not in the XDC parser. The XDC itself contains
only timing-constraint commands.

## Vivado GUI Setup

1. Copy the example XDC and hook into the integrating project directory.
2. Edit the three adaptation areas: clocks, hierarchy, and expected count.
3. If the XDC is visible in **Constraints**, open **Source File Properties**
   and clear **Used In Synthesis** and **Used In Implementation**. Keep it on
   disk. Alternatively, remove only its project reference.
4. Open **Design Runs**.
5. Right-click the implementation run, normally `impl_1`.
6. Select **Change Run Settings**.
7. Expand `opt_design`.
8. Set **Pre Tcl Script** or **tcl.pre** to the hook file.
9. Apply the setting and save the project.
10. Reset the implementation run and launch **Run Implementation**.

No Tcl Console commands are required during normal builds. Vivado runs the
hook automatically after this one-time GUI setup.

## Verification

### Run log

Open the newest implementation log and search for `axis_cdc endpoint`.
The worked example expects eight lines containing `16 cells`, followed by:

```text
Applying axis_cdc constraints from ...
Parsing XDC File [...]
Finished Parsing XDC File [...]
```

These messages prove that:

1. The hook ran.
2. Every source and destination expression matched the expected cells.
3. Vivado parsed the XDC after those checks.

There must be no matching `No cells matched`, `No clocks matched`, or
unsupported-command messages for the example XDC.

### Timing Constraints GUI

After implementation, open **Window -> Timing Constraints** and inspect
**Exceptions -> Max Delay**. Confirm all intended pointer directions exist,
the values equal their source-clock periods, and **Datapath Only** is true.

For the worked example, expect:

| Group | Delay |
|---|---:|
| Group A write pointer | 10 ns |
| Group A read pointer | 4 ns |
| Group B write pointer | 4 ns |
| Group B read pointer | 10 ns |

### Timing reports

Create a timing report between one source expression and its corresponding
stage-0 destination expression. Confirm:

- The path starts at a Gray-pointer register.
- The path ends at synchronizer stage 0.
- The requirement is max-delay and datapath-only.
- The requirement equals the source-clock period.
- Routed slack is non-negative.

A negative slack means the constraint is active but not met. An empty report
means the endpoints do not match. An ordinary cross-clock setup/hold report
instead of a max-delay requirement indicates that the exception is absent or
overridden.

## Important Restrictions

Do not apply `set_false_path` or `set_clock_groups -asynchronous` over the same
Gray-pointer paths. A broader exception can override the max-delay requirement
and remove the physical route-delay bound.

The XDC intentionally does not constrain payload RAM data, binary pointers,
synchronizer stage 0 to later stages, or unrelated CDCs. Review other design
crossings separately.

## Maintenance

Recheck the XDC and hook whenever these change:

- Clock-object names or periods.
- `axis_cdc` instance labels or parent hierarchy.
- State-record or synchronizer signal names.
- Number of matching instances.
- `GC_CDC_DEPTH`.

After a change, reset implementation and repeat the endpoint-count and timing
verification. A clean XDC parse alone is not proof that a constraint applies.
