# `run.py` Runner Specification

**Status:** Proposed
**Document scope:** Replacement repository runner for FPGA IP manifests

This document specifies the Python runner that replaces the existing shell and
batch dispatch logic. The runner reads the `.f` manifest format defined in
[`f-format.md`](f-format.md) and the tool profiles in
[`tool_capabilities.ini`](../../tool_capabilities.ini).

No `run.py` currently exists in this repository. The existing `run.bat` and
`run.sh` launchers remain available during implementation and migration.

## 1. Purpose

`run.py` is the single orchestration entry point for simulation and synthesis.
It must:

- parse one selected `.f` manifest;
- select the requested tool, mode, and testbench;
- validate source paths, metadata, and feature requirements;
- create a dedicated build directory;
- dispatch the selected backend;
- report a clear result and return a useful process exit code.

The runner is an orchestrator. Tool-specific compilation and project creation
remain in backend implementations or shared tool scripts.

## 2. Command Line

The canonical command is:

```text
run <ip> <manifest> <tool> [--tb <testbench>] [mode]
```

The Python equivalent is:

```text
python run.py <ip> <manifest> <tool> [--tb <testbench>] [mode]
```

Arguments:

| Argument | Meaning |
| --- | --- |
| `<ip>` | IP directory under the fpga-ip repository root. |
| `<manifest>` | Manifest name, with or without `.f`; resolves under `<ip>/scripts/`. |
| `<tool>` | Tool profile name, such as `modelsim`, `questa`, `vivado`, or `xsim`. |
| `--tb <name>` | Select the named `[tb:<name>]` section. |
| `--tb all` | Run every compatible testbench in the selected manifest. |
| `mode` | `batch`, `gui`, or `project`; defaults to `batch`. |

The positional order is identical on Windows and Linux.

Examples:

```text
run axis_fifo vhdl modelsim
run axis_fifo vhdl modelsim --tb uvvm gui
run axis_fifo vhdl modelsim --tb uvvm project
run axis_fifo vhdl vivado batch
run axis_fifo vhdl vivado gui
run axis_fifo vhdl vivado project
run axis_fifo vhdl xsim batch
run axis_fifo vhdl xsim gui
```

The runner may be invoked through a thin platform wrapper:

```text
run.bat axis_fifo vhdl modelsim --tb basic
./run.sh axis_fifo vhdl modelsim --tb basic
```

The wrappers must forward arguments without changing their order or meaning.

## 3. Modes

### 3.1 `batch`

`batch` is the default headless mode. The runner compiles and runs the
selected target, waits for completion, captures the result, and exits.

- ModelSim/Questa: command-line simulation.
- XSim: non-project simulation.
- Vivado: non-project batch synthesis.

### 3.2 `gui`

`gui` starts the tool GUI when supported. The runner may return after the GUI
has started, or may wait for the GUI process according to the backend contract.
That behavior must be documented by the backend and must not change the
selected source closure.

### 3.3 `project`

`project` creates or opens the native tool project and populates it from the
selected source closure.

- ModelSim/Questa: native project, such as an `.mpf` project.
- Vivado: native project, such as an `.xpr` project.
- XSim: not supported by the current capability profile; request it as an
  error rather than silently treating it as `gui` or `batch`.

`project` is distinct from `gui`. A backend may use a GUI while creating a
project, but the project mode request specifically requires native project
creation or opening.

The requested mode must appear in the selected profile's `modes` value in
`tool_capabilities.ini`.

## 4. Manifest and Testbench Selection

The runner resolves `<manifest>` as follows:

1. Add `.f` if the argument does not already have that suffix.
2. Resolve the path as `<ip>/scripts/<manifest>.f`.
3. Reject a manifest path that escapes the repository root.
4. Parse the selected manifest using the rules in `f-format.md`.

The implementation family is selected by the manifest, not by the testbench.
For example, `vhdl` selects `vhdl.f` and `sv` selects `sv.f`.

Testbench selection follows this order:

1. An explicit `--tb <name>` selects exactly `[tb:<name>]`.
2. `--tb all` selects all compatible testbenches.
3. Without `--tb`, `DEFAULT_TB` selects the named default.
4. Without `--tb` and with exactly one named testbench, select that testbench.
5. Otherwise, report an error asking the user to select a testbench.

An unnamed `[tb]` section is invalid, even when it is the only testbench. Use
`[tb:default]` when a manifest has one testbench and omit `--tb` if desired.

Vivado synthesis does not accept `--tb`. It uses `[rtl]`, `[top]`, and the
selected Vivado constraints section.

## 5. Source Closure

For simulation, the selected source closure is:

```text
[rtl] when present + [tb:<selected-name>]
```

For synthesis or a Vivado project, it is:

```text
[rtl] when present + [top] when present + [constraints:vivado]
```

A simulation-only manifest may omit both `[rtl]` and `[top]`. In that case,
the selected `[tb:<name>]` section must contain every required RTL, package,
and testbench source.

The runner must preserve manifest order. Includes are expanded in place, and
include-level `std=` overrides are applied before effective file attributes
are checked.

## 6. Capability Checks

The runner loads `tool_capabilities.ini` before validating manifest
requirements. The first `[features]` section defines the legal feature names
through `allowed_features`.

The runner must reject a manifest requirement that is not in
`allowed_features`. This is a probable typo, not a tool incompatibility.

For a legal feature, the runner computes the selected tool's effective feature
set by applying matching profiles from top to bottom in the order written in
the INI. A legal feature absent from the selected tool's effective set is a
capability mismatch.

Result behavior:

- explicit `--tb <name>` plus a missing capability: error and nonzero exit;
- `--tb all` plus a missing capability: skip that testbench and continue;
- no compatible testbench remains: nonzero exit.

Environment-sensitive features such as `uvvm` require a runtime availability
check in addition to the declared tool profile.

## 7. Tool Detection and Profiles

The runner selects a tool profile using the tool name, probe command, product
version, and edition rules from `tool_capabilities.ini`.

The runner must:

- execute the configured `probe` in a controlled manner;
- extract the canonical version using `version_re` when present;
- extract and normalize the edition using `edition_re` when present;
- apply all matching profiles in INI file order;
- reject an unsupported tool or an invalid profile configuration.

A detected edition is not silently treated as another edition. Profile
matching must follow the explicit identity and order rules in the capability
specification.

## 8. Build Directories and Artifacts

Every backend must run from a dedicated build directory. The runner must not
execute EDA tools from the repository root, an IP source directory, or the
manifest's `scripts/` directory.

Suggested build locations are backend-specific, for example:

```text
<ip>/sim/       ModelSim/Questa batch or GUI
<ip>/sim_proj/  ModelSim/Questa project mode
<ip>/xsim/      XSim simulation
<ip>/vivado/    Vivado batch synthesis
<ip>/vivado_proj/ Vivado project mode
```

Build directories and generated tool artifacts are not source inputs. The
runner should keep them separate so batch and project runs do not overwrite
each other.

## 9. Result Reporting

Every selected target produces one result:

| Result | Meaning |
| --- | --- |
| `PASS` | Backend completed successfully. |
| `FAIL` | Backend ran but compilation, elaboration, synthesis, or simulation failed. |
| `SKIP` | Target was valid but incompatible with the selected tool or environment. |
| `ERROR` | The command, manifest, profile, or target was invalid. |

Recommended output:

```text
axis_fifo / vhdl.f / modelsim / uvvm / batch
  requires: uvvm
  provides: vhdl-93, vhdl-2002, vhdl-2008, verilog, systemverilog, uvvm
  result: PASS
```

The process exit code should be zero only when every selected target is
`PASS`. A run containing `FAIL` or `ERROR` must return nonzero. A run with
only `SKIP` results should also return nonzero when no target ran successfully.

## 10. Validation Errors

The runner must reject:

- missing IP, manifest, or source file;
- an unknown manifest section or attribute;
- an unnamed `[tb]` section;
- missing or duplicate `top` in a selected testbench;
- an invalid `DEFAULT_TB` reference;
- include cycles or paths outside the allowed repository root;
- invalid VHDL standards or include-level standard overrides;
- a feature not in `allowed_features`;
- a requested mode not listed for the selected tool;
- an unsupported `--tb` selection;
- a synthesis request without a usable `[top]` section;
- an invalid tool probe, version expression, or edition expression.

## 11. Implementation Boundary

The first implementation should keep these responsibilities separate:

- `run.py`: command parsing, manifest resolution, selection, validation,
  capability checks, build-directory setup, dispatch, and result reporting;
- manifest parser: `.f` syntax, includes, source attributes, and section
  expansion;
- capability loader: INI syntax, whitelist, ordered profile application, and
  tool detection;
- backend: tool-specific compile, elaborate, simulate, synthesize, and
  project operations.

Do not add generated-script editing, automatic standard promotion, implicit
source discovery, or external-library remapping to the first implementation.
The `.f` manifest and `tool_capabilities.ini` remain the sources of truth.
