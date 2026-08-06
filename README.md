# FPGA IP Core Repository

Welcome to the FPGA IP Core Repository. This repository is a centralized collection of high-quality, parameterizable, self-contained, and reusable FPGA IP blocks designed for various digital design and signal engineering applications.

---

## Directory Structure

Each IP block is self-contained in its own subdirectory and follows a unified structure:

```
<ip_block_name>/
├── rtl/            # Production synthesizable RTL source files
├── tb/             # Simple and advanced testbenches (including UVVM when used)
├── scripts/        # Simulation launcher and GUI waveform configurations
└── README.md       # IP-specific documentation and specifications
```

---

## Available IP Cores

| IP | Path | Description |
|----|------|-------------|
| [axis_fifo](axis_fifo/README.md) | `axis_fifo/` | FWFT AXI4-Stream elastic buffer with registered handshake, SRL inference, UVVM testbench. |
| [parallel_prng](parallel_prng/README.md) | `parallel_prng/` | Multi-output XORshift PRNG with configurable parallel lanes. |
| [jitter_gen](jitter_gen/README.md) | `jitter_gen/` | CDF-based jitter injector with configurable bucket thresholds. Wraps `parallel_prng`. |
| [axis_latency_gen](axis_latency_gen/README.md) | `axis_latency_gen/` | AXI4-Stream delay element with configurable base delay + jitter. Wraps `axis_fifo` and `jitter_gen`. |
| [axis_skid_buffer](axis_skid_buffer/README.md) | `axis_skid_buffer/` | AXI4-Stream 2-deep skid buffer with bypass path. Absorbs one beat of backpressure. |
| [axi_mem_model](axi_mem_model/README.md) | `axi_mem_model/` | AXI4 read-slave that models DRAM-like latency and inter-beat gaps. Configurable widths (1–128 B), zero-latency mode, 1/cycle throughput. |
| [axilite_io](axilite_io/README.md) | `axilite_io/` | AXI4-Lite slave to register & stream bridge. Output registers (byte-strobe), input ports, AXI4-Stream push/pop channels. |
| [axi_read_tester](axi_read_tester/README.md) | `axi_read_tester/` | AXI4 read bandwidth/latency tester with scoreboard-based data verification. Configurable burst length, pacing, addressing mode (linear / PRNG). |

---

## Tool-Launcher Interface

A unified entry point `run.bat` (Windows) and `run.sh` (Linux) at the
repository root dispatches all simulation and synthesis operations:

```
run <ip> <name> [<tool>] [gui]    Run file list (optionally filter tool)
run <ip> clean                   Remove all artifacts
run <ip> all [<tool>]            Run all .f permutations (optionally filter tool)
```

### Arguments

| Argument | Description |
|----------|-------------|
| `<ip>`   | IP block directory name (e.g., `axis_fifo`). Must exist under the repo root. |
| `<name>` | File list name (without `.f` extension). Maps to `<ip>/scripts/<name>.f` which lists the source files to compile. Use `all` to run every `.f` file. Use `clean` to remove transient build artifacts. |
| `<tool>` | Optional EDA tool to invoke. Supported: `modelsim` (ModelSim/Questa simulation), `vivado` (Vivado synthesis), `xsim` (Vivado Simulator). Omit to run with all tools found on PATH. Not used when `<name>` is `clean`. |
| `[gui]`  | Optional flag to launch the GUI. For simulation tools (modelsim, xsim): opens the waveform viewer. For vivado: creates a project with Design Sources (`[rtl]` + `[top]`) and Simulation Sources (`[tb]`) properly separated, then opens the Vivado IDE for both synthesis and GUI simulation. Omit for batch/headless mode. Not valid with `all` or when `<tool>` is omitted. |
| `clean`  | Use as `<name>` to remove all transient build artifacts (`modelsim/`, `vivado/`, `xsim/`, `.Xil/`, `*.log`, etc.) |
| `all`    | Use as `<name>` to run every `.f` file. If `<tool>` is also given, only that tool is used; otherwise scans PATH for available tools. Prints a [PASS]/[FAIL]/[SKIP] summary. Exits with failure count. |

### Examples

| Command | Description |
|---------|-------------|
| `run axis_fifo vhdl` | VHDL file list, all available tools |
| `run axis_fifo vhdl  modelsim` | ModelSim VHDL testbench (batch) |
| `run axis_fifo uvvm  modelsim` | ModelSim UVVM testbench (batch) |
| `run axis_fifo sv    modelsim` | ModelSim SystemVerilog testbench (batch) |
| `run axis_fifo vhdl  modelsim gui` | ModelSim VHDL (GUI + Wave window) |
| `run axis_fifo sv    modelsim gui` | ModelSim SV (GUI + Wave window) |
| `run axis_fifo uvvm  modelsim gui` | ModelSim UVVM (GUI + Wave window) |
| `run axis_fifo vhdl  vivado` | Vivado VHDL synthesis (batch) |
| `run axis_fifo sv    vivado` | Vivado SV synthesis (batch) |
| `run axis_fifo sv    vivado gui` | Vivado SV project + GUI |
| `run axis_fifo vhdl  xsim` | XSim VHDL simulation (batch) |
| `run axis_fifo sv    xsim` | XSim SystemVerilog simulation (batch) |
| `run axis_fifo vhdl  xsim gui` | XSim VHDL (GUI) |
| `run axis_fifo all` | Run all batch permutations, print summary |
| `run axis_fifo all   modelsim` | Run all .f files with ModelSim only |
| `run axis_fifo clean` | Remove modelsim/, vivado/, xsim/ working dirs |

### Launcher

`run.py` is the single launcher for all simulation and synthesis flows (see
`common/doc/run-py.md`). The legacy launcher stack (`common/scripts/`,
`run.sh`, `run_legacy.bat`) was removed after the migration to `run.py`.

### File List (`.f`) Format

Each `<name>` in the `run` command resolves to `<ip>/scripts/<name>.f`.
These files list source files relative to the repository root
(`sub/fpga-ip/`), with optional section headers:

```ini
# [rtl]         — RTL sources (compiled by both sim and synth)
axis_fifo/rtl/axis_fifo.vhd
common/rtl/util_pkg.vhd

# [top]         — Top wrapper (synthesis only)
axis_fifo/rtl/axis_fifo_top.vhd

# [tb]          — Testbench (simulation only)
axis_fifo/tb/axis_fifo_tb.vhd
```

- Lines starting with `#` are comments or section headers.
- Section headers let one `.f` file serve both simulation (all sections)
  and synthesis (`[rtl]` + `[top]` only).
- Each data line may optionally include a VHDL standard suffix
  (e.g., `axis_fifo/tb/axis_fifo_tb.vhd 93`). Defaults to 2008.
- SystemVerilog `.sv` files are compiled with `vlog`/`xvlog -sv`.
- `.f` files without a `[top]` section are skipped by synthesis
  (simulation-only lists like `uvvm.f`).
- UVVM testbenches are auto-detected by scanning `[tb]` file contents
  for `uvvm_vvc_framework` — works regardless of `.f` filename.
- ModelSim/Questa compiles every file entry in the `.f` list, while Vivado
   synthesis consumes only `[rtl]`, `[top]`, and `[default]` sections.
- XSim skips UVVM testbenches cleanly because UVVM libraries are not part of
   the default XSim toolchain.

### Per-IP Scripts

Each IP has its own `scripts/` directory containing `.f` file lists and a
`wave.do` for GUI waveform configuration. Examples in `axis_fifo/scripts/`:

| File | Purpose |
|------|---------|
| `vhdl.f` | VHDL RTL + simple testbench |
| `sv.f` | SystemVerilog RTL + simple testbench |
| `uvvm.f` | UVVM verification (auto-detected by sim engine) |
| `uvvm_util.f` | Direct-DUT testbench using `uvvm_util` only |
| `sv-uvvm.f` | UVVM verification using the SystemVerilog DUT |
| `wave.do` | Waveform groups for GUI mode |

---

## How to Add a New IP Core

To add a new IP block (e.g., `my_ip`):

1. **Create the directory structure:**
   ```
   my_ip/
   ├── rtl/           # Synthesizable source files
   ├── tb/            # Testbench files (simple and optional UVVM)
   ├── scripts/       # File lists and wave config
   └── README.md      # IP documentation
   ```

2. **Create file lists** in `my_ip/scripts/`:
   - `vhdl.f` — VHDL sources (RTL + TB)
   - `sv.f` — SystemVerilog sources (RTL + TB) — if applicable
   - `uvvm.f` — UVVM verification sources — if applicable
   - `uvvm_util.f` — UVVM utility-library-only direct testbench — if applicable
   - `sv-uvvm.f` — UVVM verification using the SV DUT — if applicable
   - `wave.do` — (Optional) GUI waveform configuration

3. **Verify** from the repo root:
   ```
   run my_ip vhdl modelsim           # Simulate (batch)
   run my_ip vhdl vivado             # Synthesize (batch)
   run my_ip clean                   # Clean artifacts
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

---

## License

Unless specified differently within the IP subdirectory, individual cores are licensed under the **Zero-Clause BSD (0BSD)** License. This allows free integration, modification, and reproduction of the code for any purpose, commercial or private, without attribution requirements.
