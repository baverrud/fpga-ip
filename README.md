# FPGA IP Core Repository

Welcome to the FPGA IP Core Repository. This repository is a centralized
collection of high-quality, parameterizable, self-contained, and reusable
FPGA IP blocks designed for various digital design and signal engineering
applications.

Everything you need to build, simulate, and synthesize an IP is documented
here, in this single file:

1. [Quick Start](#quick-start)
2. [Repository Layout](#repository-layout)
3. [Available IP Cores](#available-ip-cores)
4. [User Manual](#user-manual)
5. [.f Manifest Format (Specification)](#f-manifest-format-specification)
6. [tool_capabilities.ini (Specification)](#tool_capabilitiesini-specification)
7. [License](#license)

---

## Quick Start

From the repository root, on a machine with the EDA tool on `PATH`:

```text
run axis_fifo vhdl modelsim      # ModelSim VHDL testbench, batch
run axis_fifo vhdl vivado        # Vivado VHDL synthesis, batch
run axis_fifo uvvm modelsim gui  # UVVM testbench, ModelSim GUI + waves
run all all all                  # Sweep: every IP/manifest/tool, batch
run clean axis_fifo              # Remove axis_fifo/.runs/ build artifacts
```

- Windows: `run` is `run.bat` (thin wrapper around `python run.py`).
- Linux: use `python3 run.py ...` with the same arguments.
- The EDA tools must be on `PATH`; no machine-specific paths are referenced
  by any script in this repository.

---

## Repository Layout

```
fpga-ip/
├── run.py                     # The single manifest runner (all tools)
├── run.bat                    # Windows entry point for run.py
├── tool_capabilities.ini      # Machine-parsed EDA tool capabilities
├── README.md                  # This file: manual + specifications
├── common/
│   └── rtl/                   # Shared RTL and AXI-Stream BFM packages
└── <ip_block>/
    ├── rtl/                   # Production synthesizable RTL source files
    ├── tb/                    # Simple and advanced testbenches (incl. UVVM)
    ├── scripts/               # .f manifests and wave.do (tracked sources)
    ├── .runs/                 # Disposable build artifacts (gitignored)
    └── README.md              # IP-specific documentation and specifications
```

Each IP block is self-contained in its own subdirectory. Its `scripts/`
folder holds the `.f` file manifests (tracked), while all generated scripts
and tool artifacts are written into `<ip>/.runs/<tool>/` (gitignored,
regenerated on every run, removed by `run clean <ip>`). See
[Build Directories and Artifacts](#build-directories-and-artifacts).

---

## Available IP Cores

| IP | Path | Description |
|----|------|-------------|
| [axis_fifo](axis_fifo/README.md) | `axis_fifo/` | FWFT AXI4-Stream elastic buffer with registered handshake, SRL inference, UVVM testbench. |
| [parallel_prng](parallel_prng/README.md) | `parallel_prng/` | Multi-output XORshift PRNG with configurable parallel lanes. |
| [jitter_gen](jitter_gen/README.md) | `jitter_gen/` | CDF-based jitter injector with configurable bucket thresholds. Wraps `parallel_prng`. |
| [axis_latency_gen](axis_latency_gen/README.md) | `axis_latency_gen/` | AXI4-Stream delay element with configurable base delay + jitter. Wraps `axis_fifo` and `jitter_gen`. |
| [axis_skid_buffer](axis_skid_buffer/README.md) | `axis_skid_buffer/` | AXI4-Stream 2-deep skid buffer with bypass path. Absorbs one beat of backpressure. |
| [axi_mem_model](axi_mem_model/README.md) | `axi_mem_model/` | AXI4 read-slave that models DRAM-like latency and inter-beat gaps. Configurable widths (1-128 B), zero-latency mode, 1/cycle throughput. |
| [axilite_io](axilite_io/README.md) | `axilite_io/` | AXI4-Lite slave to register & stream bridge. Output registers (byte-strobe), input ports, AXI4-Stream push/pop channels. |
| [axi_read_tester](axi_read_tester/README.md) | `axi_read_tester/` | AXI4 read bandwidth/latency tester with scoreboard-based data verification. Configurable burst length, pacing, addressing mode (linear / PRNG). |

---

# User Manual

This is the practical guide to driving the repository with `run.py`. The
authoritative formats are specified in the sections that follow: the
[.f Manifest Format](#f-manifest-format-specification) and
[tool_capabilities.ini](#tool_capabilitiesini-specification).

## Command Line

The canonical command:

```text
run <ip> <manifest> <tool> [--tb <testbench>] [mode]
```

Python equivalent: `python run.py <ip> <manifest> <tool> [...]`.

Arguments:

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
run clean <ip>          # Delete <ip>/.runs/ (disposable artifacts only)
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

## Build Directories and Artifacts

Automated runs keep all generated scripts and tool artifacts in a disposable,
per-IP, per-tool directory:

```text
<ip>/.runs/modelsim/    # ModelSim and Questa simulation (both use this folder)
<ip>/.runs/xsim/        # XSim simulation
<ip>/.runs/vivado/      # Vivado synthesis / project
```

- The directory is **deleted and recreated before every run**, so a run never
  inherits stale state.
- `run clean <ip>` removes the whole `<ip>/.runs/` tree.
- `.runs/` is gitignored; it is never part of the repository.
- Persistent, user-owned projects live outside `.runs/` (see below).

### Persistent Projects (`--project-dir`)

`project` mode normally creates the native project inside `<ip>/.runs/<tool>/`
and it is removed by `run clean <ip>`. To keep a project across runs, pass a
persistent directory:

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

**Runtime failure detection:** ModelSim/Questa and XSim return exit code 0
even when a VHDL assertion of severity `error`/`failure` fires during `run`
(their Tcl `onerror` catches only Tcl-level errors, not simulation breaks).
`run.py` therefore scans the run logs:

- ModelSim/Questa: `transcript` for `** Failure:` / `** Error:` lines.
- XSim: `xsim.log` for lines starting `Failure:` / `Error:`.

A batch run whose log contains such a marker is reported as FAIL even though
the tool exited 0.

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

## Environment Requirements

- The tools must be on `PATH`: `vsim` (ModelSim/Questa), `vivado` and
  `xvhdl`/`xvlog`/`xelab`/`xsim` (Vivado/XSim).
- For automatic environment setup, copy
  [`toolchains.ini.example`](toolchains.ini.example) to the ignored local
  `toolchains.ini` beside `run.py`. Alternatively use
  `%APPDATA%/fpga-ip/toolchains.ini`, or set `FPGA_IP_TOOLCHAINS` to another
  path. The file maps logical tools and versions to setup commands; its
  resulting child environment is used for both probing and the EDA run.
  The real file is ignored because launcher names and installation paths are
  machine-specific.
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

### Automatic Toolchain Setup

The local registry is an INI file with one base or version-qualified section
per logical tool:

```ini
[toolchain.modelsim]
setup = m20

[toolchain.questa]
setup = q26

[toolchain.vivado.2023.2]
setup = v23

[toolchain.vivado.2025.2]
setup = v25

[toolchain.xsim.2025.2]
setup = v25
```

When `run.py` receives `vivado --version 2025.2`, it selects
`[toolchain.vivado.2025.2]`, executes its `setup` command in a child shell,
captures the resulting `PATH` and tool variables, and uses that environment
for both `vivado -version` probing and synthesis. XSim normally shares the
corresponding Vivado setup.

Lookup precedence is:

1. The file named by `FPGA_IP_TOOLCHAINS`.
2. Ignored repository-local `toolchains.ini`.
3. `%APPDATA%/fpga-ip/toolchains.ini` on Windows.
4. `~/.config/fpga-ip/toolchains.ini` on other systems.
5. The current process environment if no registry is available.

The setup changes only child processes; it does not change the parent
PowerShell or CMD session. Single-target output prints the selected setup and
the detected tool identity, for example:

```text
toolchain: q26
detected  : questa 2025.3 / starter
```

## How to Add a New IP Core

1. **Create the directory structure:**
   ```
   my_ip/
   ├── rtl/           # Synthesizable source files
   ├── tb/            # Testbench files (simple and optional UVVM)
   ├── scripts/       # .f manifests and optional wave.do
   └── README.md      # IP documentation
   ```

2. **Create at least one manifest** in `my_ip/scripts/`, typically `vhdl.f`
   with `[rtl]`, `[top]`, and `[tb:default]` sections (see the
   [format specification](#f-manifest-format-specification) and the
   [examples](#5-examples)).

3. **Verify** from the repo root:
   ```
   run my_ip vhdl modelsim    # Simulate (batch)
   run my_ip vhdl vivado      # Synthesize (batch)
   run my_ip clean            # Clean .runs/ artifacts
   ```

### Guidelines

1. **Self-Contained Design:** Keep the core self-contained. Avoid dependencies
   on monolithic utility packages unless absolutely necessary.
2. **Directory Naming:** Use snake_case for directories and file names.
3. **Structured Verification:** Include at least one self-contained basic
   testbench (`tb/`) and ideally an advanced framework-based testbench
   (such as UVVM) when appropriate.
4. **Comprehensive Documentation:** Include a local `README.md` detailing
   generics, ports, block diagrams, architecture details, and how to run
   simulation tests.
5. **SRL & Resource Friendliness:** Code arrays carefully so they infer
   SRL/RAM primitives where appropriate (e.g., do not initialize storage
   registers with synchronous/asynchronous resets unless strictly needed).

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

# .f Manifest Format (Specification)

**Version:** 1.3 (matches the `run.py` implementation)
**Status:** Authoritative - this is the only specification.

A `.f` file is a small, human-readable manifest for one compile family of an
IP. It lives at `<ip>/scripts/<manifest>.f`, records source order, synthesis
sources, named testbench source closures, tool requirements, and per-file
VHDL standards. `run.py` is the only consumer.

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
axis_fifo/rtl/axis_fifo.vhd      std=1993
vendor/rtl/fifo_core.vhd         std=2008
axi_monitor/rtl/axi_monitor.vhd  tool=vivado,questa
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
```

`requires` values must be present in `tool_capabilities.ini` under
`[features] allowed_features`; an unknown token is a validation error
(probable typo). Missing capabilities are reported per the
[result reporting](#result-reporting-and-exit-codes) rules.

### 2.6 Includes

An `include` imports a selected section from another manifest, in place,
preserving order. The include path and section are required; `std=` is an
optional forced standard for all VHDL files expanded from that include:

```text
[rtl]
include parallel_prng/scripts/vhdl.f [rtl] std=2008

[tb:traffic]
include axi_mem_model/scripts/vhdl.f [rtl]
axi_monitor/tb/axi_monitor_tb.vhd
```

Rules:

- Include paths are relative to the **repository root**, like file entries.
- The include-level `std=` override wins over `DEFAULT_STD` and per-entry
  `std=` for VHDL files; non-VHDL files are unaffected.
- Recursive includes and include-cycle detection are supported; a cycle is an
  error.
- Duplicate sources with conflicting effective attributes are an error.

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

## 5. Examples

### 5.1 Simple standalone IP (`axis_fifo/scripts/vhdl.f`)

```text
# axis_fifo VHDL manifest
DEFAULT_STD: 2008
DEFAULT_LIB: work

[rtl]
common/rtl/util_pkg.vhd
axis_fifo/rtl/axis_fifo.vhd    std=1993

[top]
axis_fifo/rtl/axis_fifo_top.vhd

[tb:default]
top = axis_fifo_tb
requires =
common/rtl/axis_bfm_pkg.vhd
axis_fifo/tb/axis_fifo_tb.vhd
```

### 5.2 UVVM verification manifest (`axis_fifo/scripts/uvvm.f`)

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

### 5.3 Mixed-language manifest (`axis_fifo/scripts/sv-uvvm.f`)

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

### 5.4 Top entity without a wrapper file (`axi_mem_model/scripts/vhdl.f`)

When the synthesis top is a regular `[rtl]` source, `[top]` can be
metadata-only:

```text
[top]
top = axi_mem_model
```

---

# tool_capabilities.ini (Specification)

**Status:** Authoritative - this is the only specification.

`tool_capabilities.ini` records what each EDA tool actually provides in a
given environment, so `run.py` can decide **before compilation** whether a
selected target can run on a selected tool.

- A `.f` manifest declares what a target **requires**.
- `tool_capabilities.ini` declares what a tool **provides**.
- The runner compares the two and runs, skips, or fails with a clear message.

The file lives at the repository root next to `run.bat` (it is configuration
consumed by the runner, not a doc). It is machine-parsed, so keep it free of
prose and tables. Comments start with `;` or `#`. Encoding is ASCII-only.

## 1. Required section order

The file is processed top to bottom. Section order is significant and is the
user's responsibility:

```text
[features]     # define the complete feature vocabulary (must be first)
[defaults]     # define the common baseline (must be second)
[tool.*]       # apply matching profiles in file order
```

`run.py` enforces that `[features]` and `[defaults]` are the first two
sections. Put less-specific profiles before more-specific profiles; the
runner never reorders profiles by name, version, or edition.

## 2. `[features]`

The complete whitelist of allowable feature tokens:

```ini
[features]
allowed_features = vhdl-93,vhdl-2002,vhdl-2008,vhdl-2019,verilog,systemverilog,uvm,uvvm,osvvm
```

Current vocabulary:

| Feature | Meaning |
|---------|---------|
| `vhdl-93` | VHDL-1993 compilation supported |
| `vhdl-2002` | VHDL-2002 compilation supported |
| `vhdl-2008` | VHDL-2008 compilation supported |
| `vhdl-2019` | VHDL-2019 compilation supported (coarse; see below) |
| `verilog` | Verilog compilation supported |
| `systemverilog` | SystemVerilog compilation supported |
| `uvm` | UVM (SystemVerilog verification) available |
| `uvvm` | UVVM (VHDL verification) libraries available |
| `osvvm` | OSVVM (VHDL verification) available |

Rules:

- A token not in `allowed_features` is a probable typo and is rejected at
  parse time (e.g. `vhdl-209`).
- A token may be legal without being provided by the selected tool - that is
  a capability mismatch, not a vocabulary error.
- To add a custom feature, add it to `allowed_features` **before** using it in
  a profile or a manifest.

### 2.1 Partial language support

`vhdl-2019` is a **coarse** token: a tool claims only the subsets it
verifiably supports. No tool is assumed to implement the whole standard.
Subset tokens (e.g. `vhdl-2019-interfaces`) must be added to
`allowed_features` and declared in the tool profile before use in a manifest.
Constructs outside the declared subsets surface at compile time and fail
loudly - acceptable, because the runner prevents silently running a tool known
to lack a needed subset.

## 3. `[defaults]`

Most tools share a common feature set. A single `[defaults]` section declares
the baseline that every tool inherits:

```ini
[defaults]
features = vhdl-93,vhdl-2002,vhdl-2008,verilog,systemverilog
```

## 4. Tool profiles

Each profile modifies the baseline with `+` / `-` entries. Profile keys are
matched against the detected tool name, version, and edition. Key grammar:

```text
[tool.<name>]
[tool.<name>.<version>]
[tool.<name>.<edition>]
[tool.<name>.<version>.<edition>]
```

Profile keys:

| Key | Meaning |
|-----|---------|
| `probe` | Command that identifies the tool (e.g. `vsim -version`) |
| `version_re` | Regex extracting the canonical version |
| `edition_re` | Regex extracting and normalizing the edition |
| `modes` | Comma-separated supported modes: `batch,gui,project` |
| `features` | `+`/`-` delta applied to the inherited set |

`run.py` executes the base profile's `probe` command, extracts the configured
version and edition, and uses those values for matching. Explicit
`--version`/`--edition` values override the corresponding detected value. If
probing fails, matching falls back to the name-level profile.

Matching profiles are applied **in file order** (never reordered by
specificity). The effective feature set is:

```text
effective = [defaults]
            then + / - of each matching profile, in file order
```

`+feature` adds, `-feature` removes (only meaningful when an earlier profile
introduced it), a bare `feature` is `+feature`, and an empty `features =` is
the identity delta (it pins an exact version/edition for lookup without
changing features - it never resets the inherited set).

## 5. Current profiles

```ini
; ModelSim 2020.1 - Intel FPGA STARTER EDITION
[tool.modelsim]
probe = vsim -version
version_re = vsim\s+(\d+\.\d+)
edition_re = INTEL\s+FPGA\s+(STARTER)\s+EDITION
modes = batch,gui,project
features = +uvvm

[tool.modelsim.starter]
features =
[tool.modelsim.2020.1.starter]
features =

; Questa 2025.3 - Altera Starter FPGA Edition-64
[tool.questa]
probe = vsim -version
version_re = vsim\s+(\d+\.\d+)
edition_re = Altera\s+(Starter)\s+FPGA\s+Edition-64
modes = batch,gui,project
features = +uvvm

[tool.questa.starter]
features =
[tool.questa.2025.3]
features = +vhdl-2019
[tool.questa.2025.3.starter]
features =

; Vivado synthesis - coarse VHDL-2019 only
[tool.vivado]
probe = vivado -version
version_re = vivado v(\d+\.\d+)
modes = batch,gui,project
features = +vhdl-2019

; XSim - baseline only, NO VHDL-2019
[tool.xsim]
probe = xvhdl -version
version_re = Vivado Simulator v(\d+\.\d+)
modes = batch,gui
```

Notes:

- `modelsim` and `questa` both launch `vsim` but are different tool names
  with independent profiles.
- Vivado accepts VHDL-2019 for synthesis (`read_vhdl -vhdl2019`); XSim does
  not (`xvhdl` rejects `--2019`), so XSim declares no `vhdl-2019`.
- UVVM is provided by ModelSim/Questa environments, not by XSim, which is why
  the `uvvm` feature appears on the vsim-based profiles only.
- A tool with no profile is rejected by the runner as unsupported.

## 6. Adding or editing a tool

1. Keep `[features]` first; add any new feature tokens to `allowed_features`.
2. Add or edit `[defaults]` if the baseline changes.
3. Add a versionless `[tool.<name>]` profile, then version/edition-specific
   profiles when capabilities change.
4. Declare `+<feature>` on every profile that provides it.
5. Declare `requires = <feature>` on every manifest target that needs it.

Rules of thumb:

- Declare a feature only for tools that verifiably provide it; never add a
  library-dependent feature to the baseline just because one tool has it.
- A feature in the INI that nothing requires is harmless.
- A feature declared in the INI but only on non-matching tools means the
  target is rejected or skipped for those tools - the runner is working as
  intended.

## 7. Relationship to the `.f` manifest

The `.f` manifest's testbench `requires` values and the VHDL standards used
in the manifest are compared against the selected tool's effective feature
set:

- VHDL standards map to features: `1993`->`vhdl-93`, `2002`->`vhdl-2002`,
  `2008`->`vhdl-2008`, `2019`->`vhdl-2019`.
- A missing capability for an explicitly selected testbench produces a
  WARNING (exit code 3) or a skip for XSim; in a sweep it produces a `SKIP`
  row with a reason.

## 8. Runner Tests

The parser and capability layer have a dependency-free regression suite:

```text
python -m unittest discover -s tests -v
```

These tests do not require an EDA installation. They cover manifest parsing,
source existence, section normalization, duplicate-source handling, invalid
attributes, library validation, and tool identity probing. EDA simulations
remain the authoritative backend validation.

---

# License

Unless specified differently within the IP subdirectory, individual cores are licensed under the **Zero-Clause BSD (0BSD)** License. This allows free integration, modification, and reproduction of the code for any purpose, commercial or private, without attribution requirements.
