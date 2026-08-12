# .f Manifest Format (Specification)

> **Version:** 1.3 (matches the `run.py` implementation)
> **Status:** Authoritative - this is the only specification.
>
> A `.f` file is a small, human-readable manifest for one compile family of an
> IP. It lives at `<ip>/scripts/<manifest>.f`, records source order, synthesis
> sources, named testbench source closures, tool requirements, and per-file
> VHDL standards. `run.py` is the only consumer.
>
> **Related documents**
> - [README](../README.md) - repository overview and quick start
> - [User Manual](user-manual.md) - how to run things day to day
> - [tool_capabilities.ini](tool-capabilities-spec.md) - the feature tokens a
>   testbench `requires` refers to
> - [toolchains.ini](toolchains-spec.md) - machine-local tool setup

---

## 1. Overview and Core Rules

1. File order is compile order.
2. `[rtl]` is shared by synthesis and simulation when present.
3. `[top]` is synthesis-only when present.
4. A simulation-only manifest may omit both `[rtl]` and `[top]`; each
   `[tb:<name>]` section must then contain its complete source closure.
5. Each `[tb:<name>]` section is one complete simulation target; the command
   line selects it with `--tb <name>`.
6. Standards are explicit per file and are never silently promoted.
7. Testbench `requires` values use the capability feature tokens from
   `tool_capabilities.ini`; an empty value means no additional requirement.
8. Comments and manifest strings are ASCII-only so CMD, Tcl, and shell
   tooling can consume the files.

---

## 2. Syntax

### 2.1 Comments and whitespace

Comments begin with `#` and continue to the end of the line. Blank lines and
surrounding whitespace are ignored.

```text
# This is a comment
  # Indented comments are also valid
```

### 2.2 Global directives

Directives appear before the first section header, in `KEY: VALUE` form:

```text
DEFAULT_STD: 2008
DEFAULT_LIB: work
```

| Directive | Meaning | Default |
|-----------|---------|---------|
| `DEFAULT_STD` | VHDL standard for entries without `std=` | `2008` |
| `DEFAULT_LIB` | VHDL library; currently must be `work` | `work` |
| `DEFAULT_TB` | Named testbench used when `--tb` is omitted | unset |

Valid standards are `1993`, `2002`, `2008`, `2019`. `DEFAULT_LIB` and
`DEFAULT_TB` are optional. The runner currently supports only the local
`work` library; non-work libraries are rejected rather than silently ignored.
External libraries such as UVVM are supplied by the simulator environment and
must not be remapped.

### 2.3 Sections

A section header is `[<name>]`. The vocabulary is deliberately small and
closed; an unknown section is a validation error:

| Section | Meaning |
|---------|---------|
| `[rtl]` | Shared synthesizable and simulation sources |
| `[top]` | Synthesis top wrapper / synthesis-only sources |
| `[tb:<name>]` | One named simulation target (metadata + sources) |
| `[wave:<name>]` | Portable waveform view (parsed; not yet consumed by backends) |
| `[constraints:<tool>]` | Tool-specific constraints (e.g. Vivado XDC), used in synthesis |

Rules:

- Section names are case-insensitive tags; the runner understands exactly the
  vocabulary above.
- An **unnamed `[tb]` section is not supported** - use `[tb:<name>]`.
- Duplicate sections are an error. A typo such as `[tbb]` is an error, not a
  silent no-op.
- `[wave:]` sections and `wave =` metadata are parsed and validated but are
  **not yet consumed** by any backend; GUI runs currently add a default
  `add wave /<top>/*` view.

### 2.4 File entries

A file entry is a path relative to the **repository root** (the directory
containing `run.py` and `tool_capabilities.ini`), optionally followed by
space-separated `key=value` attributes:

```text
<relative_path> [std=<std>] [lib=<lib>] [tool=<t1,t2,...>]
```

| Attribute | Meaning | Default |
|-----------|---------|---------|
| `std=` | Explicit VHDL standard: `1993`, `2002`, `2008`, `2019` | `DEFAULT_STD` |
| `lib=` | Compile library; currently must be `work` | `DEFAULT_LIB` |
| `tool=` | Comma-separated allow-list; file is skipped for tools not listed | all tools |

Example:

```text
[rtl]
common/rtl/util_pkg.vhd
axis_fifo/rtl/axis_fifo.vhd      std=2008
vendor/rtl/fifo_core.vhd         std=2008
axi_monitor/rtl/axi_monitor.vhd              tool=vivado,questa
```

Notes:

- SystemVerilog `.sv` files are compiled with `vlog`/`xvlog -sv`; `std=` is
  ignored for them.
- `DEFAULT_LIB` and `lib=` are retained for format compatibility, but only
  `work` is supported until the backends gain multi-library handling.
- There are no `tb_top`, `feature`, or `exact_std` file attributes. Testbench
  metadata belongs to its `[tb:<name>]` section, and standards are never
  silently promoted.

### 2.5 Section metadata

Inside a section, a line `identifier = value` is metadata; a line whose first
token contains no `=` is a file path. Testbench sections support:

| Key | Meaning |
|-----|---------|
| `top` | Exact simulation entity/module to elaborate (required for a TB) |
| `time_res` | Optional simulator resolution override, e.g. `ps` or `fs` |
| `requires` | Comma-separated capability feature tokens, e.g. `uvvm` (empty = none) |
| `generics` | Comma-separated top-level generic overrides for `top`, e.g. `GC_TS=13ns, GC_TM=10ns`; emitted as `-g<name>=<value>` (ModelSim/Questa) or `-generic_top name=value` (XSim). Values must not contain spaces. |
| `wave` | Optional name of a `[wave:<name>]` view (parsed, not yet consumed) |

```text
[tb:default]
top = axis_fifo_tb
requires =
common/rtl/axis_bfm_pkg.vhd
axis_fifo/tb/axis_fifo_tb.vhd

[tb:uvvm]
top = axis_fifo_uvvm_tb
time_res = fs
requires = uvvm
axis_fifo/tb/axis_fifo_uvvm_th.vhd
axis_fifo/tb/axis_fifo_uvvm_tb.vhd

[tb:rev]
top = axis_fifo_tb
generics = GC_TS=13ns, GC_TM=10ns
axis_fifo/tb/axis_fifo_tb.vhd
```

`generics` overrides top-level generics of the `top` entity (for example
clock periods), so one parameterized testbench can serve multiple
configurations without a second TB file. The `[tb:rev]` example runs the
same `axis_fifo_tb` file with different periods via
`run axis_fifo vhdl modelsim --tb rev`.

`requires` values must be present in `tool_capabilities.ini` under
`[features] allowed_features`; an unknown token is a validation error
(probable typo). Missing capabilities are reported per the
[result reporting rules](user-manual.md#result-reporting-and-exit-codes).

### 2.6 Includes

An `include` imports a selected section from another manifest, in place,
preserving order. The include path and section are required; `std=` is an
optional forced standard for all VHDL files expanded from that include:

```text
[rtl]
include parallel_prng/scripts/vhdl.f [rtl] std=2008

[tb:traffic]
include axi_mem_model/scripts/vhdl.f [rtl]
axi_traffic_gen/tb/axi_req_gen_tb.vhd
```

Rules:

- Include paths are relative to the **repository root**, like file entries.
- The include-level `std=` override wins over `DEFAULT_STD` and per-entry
  `std=` for VHDL files; non-VHDL files are unaffected.
- Recursive includes and include-cycle detection are supported; a cycle is an
  error.
- Duplicate sources with conflicting effective attributes are an error.

---

## 3. Target Selection and Tool Behavior

The selected source closure is explicit; absent sections contribute no files:

```text
simulation = [rtl, if present] + [tb:<selected-name>]
synthesis  = [rtl, if present] + [top, if present] + [constraints:<tool>]
```

Simulation and synthesis never compile all sections indiscriminately.

### 3.1 ModelSim and Questa

Compile the selected ordered source list into the local `work` library
(`vcom -<std>` per file), elaborate the declared `top`, and run. `gui` opens
the waveform viewer; `project` creates a native `.mpf` project. UVVM
libraries remain external precompiled libraries.

### 3.2 XSim

XSim needs **one VHDL standard per `work` library**, so all VHDL sources are
compiled at the manifest `DEFAULT_STD`; per-file `std=` overrides are ignored
(a note is printed when a manifest mixes standards). A testbench whose
`requires` XSim does not provide (e.g. `uvvm`) is skipped. XSim has no
`project` mode.

### 3.3 Vivado

Synthesis ignores all `[tb:<name>]` and `[wave:<name>]` sections. It uses
`[rtl]`, `[top]`, and the selected Vivado constraints section. A manifest
with no `[top]` is simulation-only and is skipped by synthesis. The synthesis
top entity is taken from the `[top]` section's `top = <entity>` metadata, or
by scanning the `[top]` files for an `entity ... is` declaration. `project`
mode creates a native `.xpr` with design sources in `sources_1`, constraints
in `constrs_1`, and testbench sources in `sim_1`.

---

## 4. Validation Rules

`run.py` rejects:

- missing files or manifests;
- unknown sections, attributes, or invalid standards;
- a bare (unnamed) `[tb]` section;
- duplicate sections;
- a missing `top` metadata value in a selected testbench;
- a `--tb` name that does not exist;
- a `requires` token not in `allowed_features`;
- include cycles and paths escaping the repository root;
- a requested mode not listed in the tool's `modes`;
- synthesis requests without a `[top]` section.

---

## 5. Examples

### 5.1 Smallest useful simulation manifest

This is the compact shape for an IP with one RTL file and one testbench:

```text
DEFAULT_STD: 2008

[rtl]
my_ip/rtl/my_ip.vhd

[tb:default]
top = my_ip_tb
my_ip/tb/my_ip_tb.vhd
```

`DEFAULT_LIB` is omitted here because its default is `work`. The sole
testbench is selected automatically, so these commands are equivalent:

```text
run my_ip vhdl modelsim
run my_ip vhdl modelsim --tb default
```

### 5.2 Simple standalone IP (`axis_fifo/scripts/vhdl.f`)

```text
# axis_fifo VHDL manifest
DEFAULT_STD: 2008
DEFAULT_LIB: work

[rtl]
common/rtl/util_pkg.vhd
axis_fifo/rtl/axis_fifo.vhd    std=2008

[top]
axis_fifo/rtl/axis_fifo_top.vhd

[tb:default]
top = axis_fifo_tb
requires =
common/rtl/axis_bfm_pkg.vhd
axis_fifo/tb/axis_fifo_tb.vhd
```

### 5.3 UVVM verification manifest (`axis_fifo/scripts/uvvm.f`)

```text
DEFAULT_STD: 2008
DEFAULT_LIB: work

[rtl]
common/rtl/util_pkg.vhd
axis_fifo/rtl/axis_fifo.vhd

[tb:default]
top = axis_fifo_uvvm_tb
requires = uvvm
time_res = fs
axis_fifo/tb/axis_fifo_uvvm_th.vhd
axis_fifo/tb/axis_fifo_uvvm_tb.vhd
```

### 5.4 Mixed-language manifest (`axis_fifo/scripts/sv-uvvm.f`)

```text
DEFAULT_STD: 2008
DEFAULT_LIB: work

[rtl]
common/rtl/util_pkg.vhd
axis_fifo/rtl/axis_fifo.sv

[tb:default]
top = axis_fifo_uvvm_tb
requires = uvvm
time_res = fs
axis_fifo/tb/axis_fifo_uvvm_th.vhd
axis_fifo/tb/axis_fifo_uvvm_tb.vhd
```

### 5.5 Complete manifest with includes, multiple testbenches, waves, and constraints

This example shows the larger shape used when one manifest serves simulation,
UVVM, synthesis, and Vivado constraints:

```text
DEFAULT_STD: 2008
DEFAULT_LIB: work
DEFAULT_TB: default

[rtl]
common/rtl/util_pkg.vhd
include parallel_prng/scripts/vhdl.f [rtl]
my_ip/rtl/my_ip.vhd std=2008

[top]
top = my_ip
my_ip/rtl/my_ip_top.vhd

[tb:default]
top = my_ip_tb
requires =
wave = debug
common/rtl/axis_bfm_pkg.vhd
my_ip/tb/my_ip_tb.vhd

[tb:uvvm]
top = my_ip_uvvm_tb
time_res = fs
requires = uvvm
my_ip/tb/my_ip_uvvm_th.vhd
my_ip/tb/my_ip_uvvm_tb.vhd

[wave:debug]
my_ip/tb/waves.do

[constraints:vivado]
my_ip/constraints/my_ip.xdc
```

The default command selects `[tb:default]`; use `--tb uvvm` for the UVVM
target. Vivado ignores the testbench and wave sections and uses the RTL, top,
and Vivado constraint closure.

### 5.6 Top entity without a wrapper file (`axi_mem_model/scripts/vhdl.f`)

When the synthesis top is a regular `[rtl]` source, `[top]` can be
metadata-only:

```text
[top]
top = axi_mem_model
```

---

## See Also

- [User Manual](user-manual.md) - running targets, sweeps, exit codes
- [tool_capabilities.ini](tool-capabilities-spec.md) - the feature tokens
  used by `requires =`
