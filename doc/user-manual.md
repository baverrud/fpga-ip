# User Manual

> How to drive this repository with `run.py` - every command, mode, and
> workflow you need day to day.
>
> **Related documents**
> - [README](../README.md) - repository overview and quick start
> - [.f Manifest Format](f-manifest-spec.md) - what a manifest file looks like
> - [tool_capabilities.ini](tool-capabilities-spec.md) - how tools and their
>   features are declared
> - [toolchains.ini](toolchains-spec.md) - machine-local tool setup

---

## Command Line

The canonical command:

```text
run <ip> <manifest> <tool> [--tb <testbench>] [mode]
```

Python equivalent: `python run.py <ip> <manifest> <tool> [...]`.

### Arguments

| Argument | Meaning |
|----------|---------|
| `<ip>` | IP directory under the fpga-ip root, or `all` for a sweep. |
| `<manifest>` | Manifest base name (`vhdl`, `sv`, `uvvm`, `uvvm_util`, `sv-uvvm`), with or without `.f`; resolves to `<ip>/scripts/<manifest>.f`. Or `all`. |
| `<tool>` | Tool profile name: `modelsim`, `questa`, `vivado`, `xsim`, or `all`. |
| `--tb <name>` | Select exactly the `[tb:<name>]` section. |
| `--tb all` | Run every compatible testbench in the selected manifest. |
| `--part <part>` | Vivado target part (default: `xc7a35tftg256-1`). |
| `--version`, `--edition` | Select/verify a tool version/edition profile and its local setup. |
| `--project-dir <dir>` | Persistent project directory (IP-relative), project mode only. |
| `mode` | `batch` (default), `gui`, or `project`. `all` targets are batch-only. |

Separate subcommands:

```text
run clean <ip>                    # Delete <ip>/.runs/ (disposable artifacts only)
run <ip|all> <manifest|all> <tool|all>   # Sweep matrix, batch only
```

### Examples

| Command | Description |
|---------|-------------|
| `run axis_fifo vhdl modelsim` | ModelSim VHDL testbench (batch) |
| `run axis_fifo vhdl modelsim --tb default` | Same, explicit testbench |
| `run axis_fifo uvvm modelsim` | ModelSim UVVM testbench (batch) |
| `run axis_fifo sv modelsim` | ModelSim SystemVerilog testbench (batch) |
| `run axis_fifo vhdl modelsim gui` | ModelSim VHDL (GUI + Wave window) |
| `run axis_fifo vhdl modelsim project` | ModelSim native project + GUI |
| `run axis_fifo vhdl vivado` | Vivado VHDL synthesis (batch) |
| `run axis_fifo vhdl vivado gui` | Vivado non-project GUI synthesis |
| `run axis_fifo vhdl vivado project` | Vivado native `.xpr` project + GUI |
| `run axis_fifo vhdl vivado --version 2023.2` | Vivado 2023.2 synthesis using the matching local toolchain |
| `run axis_fifo vhdl vivado --version 2025.2` | Vivado 2025.2 synthesis using the matching local toolchain |
| `run axis_fifo vhdl vivado --version 2026.1` | Vivado 2026.1 synthesis using the matching local toolchain |
| `run axis_fifo vhdl xsim` | XSim VHDL simulation (batch) |
| `run axis_fifo vhdl xsim --version 2023.2` | XSim from Vivado 2023.2 |
| `run axis_fifo vhdl xsim --version 2025.2` | XSim from Vivado 2025.2 |
| `run axis_fifo vhdl xsim --version 2026.1` | XSim from Vivado 2026.1 |
| `run axis_fifo vhdl xsim gui` | XSim VHDL (GUI) |
| `run axis_fifo vhdl modelsim --version 2020.1` | ModelSim 2020.1 simulation |
| `run axis_fifo vhdl questa --version 2025.3` | Questa 2025.3 simulation with VHDL-2019 capability |
| `run axis_fifo vhdl modelsim project --project-dir proj/modelsim` | Persistent ModelSim project |
| `run all all all` | Sweep every IP/manifest/tool (batch) |
| `run all vhdl modelsim` | Sweep every IP, `vhdl.f`, ModelSim |
| `run axis_fifo all modelsim` | Sweep every manifest of one IP with ModelSim |
| `run clean axis_fifo` | Remove `axis_fifo/.runs/` |

### A Typical Workflow

For a new or changed IP, this is usually enough:

```text
# 1. Run the default testbench in batch mode.
run my_ip vhdl modelsim

# 2. Run the same sources in another simulator.
run my_ip vhdl questa

# 3. Synthesize the RTL with Vivado.
run my_ip vhdl vivado

# 4. Open a GUI when you need waveforms or an interactive project.
run my_ip vhdl modelsim gui
run my_ip vhdl modelsim project --project-dir proj/modelsim

# 5. Remove disposable output when it is no longer useful.
run clean my_ip
```

A successful batch run ends with `result : PASS`. A failure returns exit code
`1`; inspect the generated script and the tool log under `<ip>/.runs/`.

---

## Modes

| Mode | Meaning |
|------|---------|
| `batch` | Headless: compile, run, report result, exit. Default. |
| `gui` | Launch the tool GUI with the waveform viewer (simulation) or the loaded design (Vivado); blocks until the GUI closes. |
| `project` | Create/open the tool's native project (`.mpf` for ModelSim/Questa, `.xpr` for Vivado) and open the GUI. |

The requested mode must be listed in the selected tool's `modes` value in
`tool_capabilities.ini`:

| Tool | Supported modes |
|------|-----------------|
| `modelsim`, `questa` | `batch`, `gui`, `project` |
| `vivado` | `batch`, `gui`, `project` |
| `xsim` | `batch`, `gui` (no project mode) |

---

## Build Directories and Artifacts

Automated runs keep all generated scripts and tool artifacts in a disposable,
per-IP, per-tool directory:

```text
<ip>/.runs/modelsim/    # ModelSim and Questa simulation (both use this folder)
<ip>/.runs/xsim/        # XSim simulation
<ip>/.runs/vivado/      # Vivado synthesis / project
```

Key points:

- The directory is **deleted and recreated before every run**, so a run never
  inherits stale state.
- `run clean <ip>` removes the whole `<ip>/.runs/` tree.
- `.runs/` is gitignored; it is never part of the repository.
- Persistent, user-owned projects live outside `.runs/` (see below).

### Persistent Projects (`--project-dir`)

`project` mode normally creates the native project inside
`<ip>/.runs/<tool>/` and it is removed by `run clean <ip>`. To keep a project
across runs, pass a persistent directory:

```text
run axis_fifo vhdl modelsim project --project-dir proj/modelsim
run axis_fifo vhdl vivado   project --project-dir proj/vivado
```

- The path is **IP-relative**: `proj/modelsim` means `<ip>/proj/modelsim`
  (the mirror of the `.runs` layout, so each IP owns its projects).
- Absolute paths are also accepted, but must stay below the fpga-ip root and
  outside `.runs/`.
- The directory must be **new or empty**; run.py refuses to overwrite a
  non-empty directory.
- run.py **never deletes** a `--project-dir` project, including `run clean`.

---

## Testbench Selection

A manifest may contain several named `[tb:<name>]` sections. Selection rules:

| Invocation | Meaning |
|------------|---------|
| `--tb <name>` | Run exactly `[tb:<name>]` |
| `--tb all` | Run every compatible testbench in the manifest |
| no `--tb`, `DEFAULT_TB` set | Use the named default testbench |
| no `--tb`, exactly one TB | Use the only testbench implicitly |
| no `--tb`, multiple TBs, no default | Error; choose with `--tb` |
| `vivado` + `--tb` | Error; testbenches are not synthesis targets |

---

## The `all` Sweep

`run <ip|all> <manifest|all> <tool|all>` runs every combination in batch mode
and prints a live, aligned progress table with `PASS`/`FAIL`/`SKIP` results:

```text
IP            MANIFEST  TB       TOOL      RESULT
axis_fifo     vhdl      default  modelsim  PASS
axis_fifo     vhdl      default  vivado    PASS
...
Summary: 8 passed, 1 failed, 2 skipped (11 total)
```

- `SKIP` rows carry a reason (unknown tool, missing feature such as `uvvm` on
  `xsim`, missing VHDL standard, no `[top]` section for Vivado synthesis).
- `FAIL` rows list the manifest/tool and exit code at the end.
- The sweep is batch-only; other modes are rejected.
- The exit code is nonzero if any target failed.

> **Tip - diagnosing a sweep failure.** Failed simulator runs are archived
> automatically under `<ip>/.runs/failures/` with the generated script,
> transcript, tool output, and environment metadata. Set the environment
> variable `FPGA_IP_DIAGNOSTICS=1` to also archive successful runs (under
> `.runs/diagnostics/`) and to stop the sweep at the first failure - useful
> when chasing an intermittent problem.

PowerShell:

```powershell
$env:FPGA_IP_DIAGNOSTICS = "1"
run all all all
```

CMD:

```cmd
set FPGA_IP_DIAGNOSTICS=1
run all all all
```

With diagnostics enabled, the sweep stops after the first failure. This keeps
the relevant transcript easy to find and archives successful comparison runs
as well.

---

## Result Reporting and Exit Codes

For a single target, `run.py` prints the target, top, required features, the
source closure (compile order, `[OK]`/`[MISS]` per file), the generated
script path, and a result line. Exit codes:

| Code | Meaning |
|------|---------|
| `0` | PASS - every selected target ran cleanly |
| `1` | FAIL - compilation, elaboration, synthesis, or simulation failed |
| `2` | Usage, manifest, profile, or validation error |
| `3` | WARNING - target ran but a declared capability is missing |

**Runtime failure detection.** ModelSim/Questa and XSim return exit code 0
even when a VHDL assertion of severity `error`/`failure` fires during `run`
(their Tcl `onerror` catches only Tcl-level errors, not simulation breaks).
`run.py` therefore scans the run logs:

- ModelSim/Questa: `transcript` for `** Failure:` / `** Error:` lines.
- XSim: `xsim.log` for lines starting `Failure:` / `Error:`.

A batch run whose log contains such a marker is reported as FAIL even though
the tool exited 0.

---

## Generated Scripts

Generated scripts are build artifacts written into the run directory, with a
header showing the exact `run` command that re-creates them. They can also be
run directly from their directory on a machine with the tool on `PATH`:

| Tool | Script pattern | Direct invocation |
|------|----------------|-------------------|
| ModelSim/Questa | `sim_<manifest>_<tool>_<tb>_<mode>.tcl` | `cd <ip>/.runs/modelsim && vsim [-c] -do <script>` |
| XSim | `sim_<manifest>_xsim_<tb>_<mode>.tcl` | `cd <ip>/.runs/xsim && vivado -mode tcl -source <script>` |
| Vivado | `synth_<manifest>_vivado_<mode>.tcl` | `cd <ip>/.runs/vivado && vivado -mode batch -source <script>` |

Notes:

- For `modelsim` the tool tag is shortened to `msim` in the filename, e.g.
  `sim_vhdl_msim_default_batch.tcl`.
- XSim scripts are self-contained wrappers. The outer Vivado Tcl phase
  performs compile (`xvhdl`/`xvlog`) and elaboration (`xelab`) through Tcl
  `exec`, then launches XSim with the same file as `--tclbatch`. The inner
  XSim phase runs the snapshot; GUI mode elaborates with `-debug all` and adds
  the default wave view.
- Do not launch the generated wrapper with `xsim` directly. `xsim` is launched
  by the outer Vivado Tcl phase after the snapshot exists.
- The scripts locate the repository via a `set repo_root ...` line and refuse
  to run if `tool_capabilities.ini` is missing.
- ModelSim/Questa GUI scripts provide a `recompile` helper: after editing a
  source, type `recompile` to rebuild and re-run without leaving the GUI.

---

## Environment Requirements

- The tools must be on `PATH`: `vsim` (ModelSim/Questa), `vivado` and
  `xvhdl`/`xvlog`/`xelab`/`xsim` (Vivado/XSim).
- For automatic environment setup, use a local `toolchains.ini`. See the
  [toolchains.ini specification](toolchains-spec.md) for the file format,
  the lookup precedence, and how `run.py` captures the tool environment.
- Example version selection:
  `run axis_fifo vhdl vivado --version 2025.2`. If the setup command produces
  another version, run.py stops with a clear mismatch error.
- Before capability matching, `run.py` executes each profile's `probe` command
  and extracts the configured version and edition. `--version` and
  `--edition` override the detected values; if a probe is unavailable, the
  name-level profile is used.
- UVVM libraries are supplied by the simulator environment (precompiled);
  `run.py` never remaps them and never issues `vmap` for external libraries.
- ModelSim/Questa `project` mode needs a writable local `modelsim.ini` and a
  cleared `%MODELSIM%`; `run.py` sets both up automatically (it copies the
  global ini into the run directory and clears `%MODELSIM%` for the child).

---

## How to Add a New IP Core

1. **Create the directory structure:**
   ```text
   my_ip/
   |-- rtl/           # Synthesizable source files
   |-- tb/            # Testbench files (simple and optional UVVM)
   |-- scripts/       # .f manifests and optional wave.do
   `-- README.md      # IP documentation
   ```

2. **Create at least one manifest** in `my_ip/scripts/`, typically `vhdl.f`
   with `[rtl]`, `[top]`, and `[tb:default]` sections (see the
   [manifest specification](f-manifest-spec.md)).

3. **Verify** from the repo root:
   ```text
   run my_ip vhdl modelsim    # Simulate (batch)
   run my_ip vhdl vivado      # Synthesize (batch)
   run clean my_ip            # Clean .runs/ artifacts
   ```

### Guidelines

1. **Self-Contained Design.** Keep the core self-contained. Avoid dependencies
   on monolithic utility packages unless absolutely necessary.
2. **Directory Naming.** Use snake_case for directories and file names.
3. **Structured Verification.** Include at least one self-contained basic
   testbench (`tb/`) and ideally an advanced framework-based testbench (such
   as UVVM) when appropriate.
4. **Comprehensive Documentation.** Include a local `README.md` detailing
   generics, ports, block diagrams, architecture details, and how to run
   simulation tests.
5. **SRL & Resource Friendliness.** Code arrays carefully so they infer
   SRL/RAM primitives where appropriate (e.g., do not initialize storage
   registers with synchronous/asynchronous resets unless strictly needed).

---

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `unsupported tool '<t>'` | No profile for `<t>` in `tool_capabilities.ini`; run with `modelsim`, `questa`, `vivado`, or `xsim`. |
| `mode '<m>' not supported by '<tool>'` | The tool's `modes` in `tool_capabilities.ini` does not list `<m>` (e.g. XSim has no `project`). |
| `manifest has no testbench section` / `multiple testbenches; select one with --tb` | Add `[tb:...]` sections or select with `--tb`. |
| `unknown section [...]` | Section name typo; allowed: `[rtl]`, `[top]`, `[tb:<name>]`, `[wave:<name>]`, `[constraints:<tool>]`. Bare `[tb]` is invalid. |
| `source file not found: <path>` | A listed path does not exist; paths are relative to the fpga-ip root. |
| `requires token(s) not in allowed_features` | A `requires =` value is not in `tool_capabilities.ini` `[features] allowed_features`; probable typo. |
| `project directory is not empty` | `--project-dir` must be new/empty; point at a fresh directory. |
| Batch passes but the DUT is broken | Runtime assertion failures; check `transcript` / `xsim.log` markers (see [exit codes](#result-reporting-and-exit-codes)). |
| `run all` on `xsim` SKIPs UVVM manifests | XSim ships no UVVM libraries; the sweep skips them with a reason. |

---

## See Also

- [README](../README.md) - repository overview and IP list
- [.f Manifest Format](f-manifest-spec.md)
- [tool_capabilities.ini](tool-capabilities-spec.md)
- [toolchains.ini](toolchains-spec.md)
