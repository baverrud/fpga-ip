# FPGA IP Core Repository

Welcome to the FPGA IP Core Repository - a centralized collection of
high-quality, parameterizable, self-contained, and reusable FPGA IP blocks
for digital design and signal engineering.

This document is the **entry point**. For hands-on usage see the
[User Manual](doc/user-manual.md); each file format has its own
specification.

> **Related documents**
> - [User Manual](doc/user-manual.md) - all `run.py` commands and workflows
> - [.f Manifest Format](doc/f-manifest-spec.md) - the `.f` file format
> - [tool_capabilities.ini](doc/tool-capabilities-spec.md) - what tools provide
> - [toolchains.ini](doc/toolchains-spec.md) - machine-local tool setup

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

For every command, option, mode, and workflow, see the
[User Manual](doc/user-manual.md).

---

## Repository Layout

```text
fpga-ip/
├── run.py                     # The single manifest runner (all tools)
├── run.bat                    # Windows entry point for run.py
├── tool_capabilities.ini      # Machine-parsed EDA tool capabilities
├── toolchains.ini.example     # Example machine-local tool setup (gitignored real file)
├── README.md                  # This file: overview + index
├── doc/                       # Guides and specifications
├── tools/                     # Repository-wide development utilities
├── common/rtl/                # Shared RTL and AXI-Stream BFM packages
└── <ip_block>/                # One self-contained IP core per directory
    ├── rtl/                   # Production synthesizable RTL source files
    ├── tb/                    # Simple and advanced testbenches (incl. UVVM)
    ├── scripts/               # .f manifests and wave.do (tracked sources)
    ├── .runs/                 # Disposable build artifacts (gitignored)
    └── README.md              # IP-specific documentation
```

Each IP is self-contained in its own subdirectory. Generated scripts and tool
artifacts are written into `<ip>/.runs/<tool>/` (gitignored, regenerated on
every run, removed by `run clean <ip>`).

---

## Available IP Cores

| IP | Path | Description |
|----|------|-------------|
| [axis_fifo](axis_fifo/README.md) | `axis_fifo/` | FWFT AXI4-Stream elastic buffer with registered handshake, SRL inference, UVVM testbench. |
| [axis_cdc](axis_cdc/README.md) | `axis_cdc/` | AXI4-Stream clock-domain converter (CDC) via Gray-pointer asynchronous FIFO. Line-rate throughput on both sides. |
| [parallel_prng](parallel_prng/README.md) | `parallel_prng/` | Multi-output XORshift PRNG with configurable parallel lanes. |
| [jitter_gen](jitter_gen/README.md) | `jitter_gen/` | CDF-based jitter injector with configurable bucket thresholds. Wraps `parallel_prng`. |
| [axis_latency_gen](axis_latency_gen/README.md) | `axis_latency_gen/` | AXI4-Stream delay element with configurable base delay + jitter. Wraps `axis_fifo` and `jitter_gen`. |
| [axis_skid_buffer](axis_skid_buffer/README.md) | `axis_skid_buffer/` | AXI4-Stream 2-deep skid buffer with bypass path. Absorbs one beat of backpressure. |
| [axis_downsizer](axis_downsizer/README.md) | `axis_downsizer/` | AXI4-Stream width downsizer (512 -> 128 default, 4:1). LSB-first unpacking, 250 MHz output line rate. |
| [axis_upsizer](axis_upsizer/README.md) | `axis_upsizer/` | AXI4-Stream width upsizer (128 -> 512 default, 4:1). LSB-first packing, 250 MHz line rate. |
| [pulse_extender](pulse_extender/README.md) | `pulse_extender/` | Level-triggered pulse extender. A high on `trigger` sampled at a rising edge while idle drives `pulse_out` high for a configurable number of clock cycles. |
| [axi_mem_model](axi_mem_model/README.md) | `axi_mem_model/` | AXI3/AXI4 read-slave that models DRAM-like latency and inter-beat gaps. Configurable widths (1-128 B), zero-latency mode, 1/cycle throughput. |
| [axi_monitor](axi_monitor/README.md) | `axi_monitor/` | Passive client read-transaction monitor for the `req_*` / `rsp_*` interfaces (no ID). Taps a client of `axi_read_bridge`, validates every rsp beat against a scoreboard, and accumulates transaction, latency, burst-length, and protocol-error statistics. |
| [axi_r_demux](axi_r_demux/README.md) | `axi_r_demux/` | AXI4 read-data channel demultiplexer with per-client elastic FIFOs. 4 clients, 32-bit, depth-32 default; 250 MHz. |
| [axilite_io](axilite_io/README.md) | `axilite_io/` | AXI4-Lite slave to register & stream bridge. Output registers (byte-strobe), input ports, AXI4-Stream push/pop channels. |
| [axi_traffic_gen](axi_traffic_gen/README.md) | `axi_traffic_gen/` | Lightweight client read-request (`req_*`) traffic generator. Provides `axi_req_gen` with configurable pace, linear/PRNG addressing, and optional random burst lengths. |

---

## Documentation

| Document | What it covers |
|----------|----------------|
| [User Manual](doc/user-manual.md) | All `run.py` commands, modes, build directories, sweeps, exit codes, troubleshooting |
| [HDL Format Guide](doc/hdl-format-guide.md) | `hdl-format.py` styles, wrapper formatting, README code blocks, and validation options |
| [.f Manifest Format](doc/f-manifest-spec.md) | The `.f` file format used by `<ip>/scripts/*.f` |
| [tool_capabilities.ini](doc/tool-capabilities-spec.md) | How tools and their capability features are declared |
| [toolchains.ini](doc/toolchains-spec.md) | Machine-local tool setup registry (per-machine, gitignored) |

Each IP directory also has its own `README.md` with generics, ports, block
diagrams, and how to run that IP's tests.

---

## License

Unless specified differently within the IP subdirectory, individual cores are
licensed under the **Zero-Clause BSD (0BSD)** License. This allows free
integration, modification, and reproduction of the code for any purpose,
commercial or private, without attribution requirements.
