# Specification Plan: Proprietary HDL File Manifest Format (`.f`)

**Document Title:** Specification for Proprietary FPGA/ASIC File Manifest (`.f`)  
**Version:** 1.0  
**Status:** Approved Specification  
**Target Domain:** FPGA & ASIC IP Repository Management (VHDL / Mixed-Language)  

---

## 1. Overview & Objectives

The `.f` manifest format is a human-readable, line-oriented text specification designed to declare source files, compilation order, target dependencies, and tool requirements for FPGA IP cores. 

It solves the challenges of VHDL compilation ordering, multi-library mapping, mixed-standard VHDL (1993, 2008, 2019), and EDA tool capabilities (e.g., Vivado, QuestaSim, GHDL, Quartus) without relying on heavyweight external build tools or vendor-locked project files.

### Core Philosophy & Rules:
1. **Explicit Top-to-Bottom Order:** The vertical order of files in the manifest defines the compilation order.
2. **Convention Over Configuration:** Defaults minimize syntax noise (e.g., testbench entity names default to matching file names).
3. **Agnostic Sectioning:** Files are grouped into arbitrary targets (`[rtl]`, `[top]`, `[tb]`, `[constraints]`) managed by string tags.
4. **Contextual Relative Paths:** Every file path is relative to the directory containing the `.f` file in which it is written.
5. **Tool & Version Awareness:** Inline metadata attributes handle language standards, tool exclusions, and framework requirements without duplicating file lists.

---

## 2. Syntax Specification

### 2.1 Comments and Whitespace
* **Comments:** Any text following a `#` character up to the end of the line is a comment and is ignored.
* **Blank Lines:** Empty lines or lines containing only whitespace are ignored.
* **Indentation:** Leading and trailing whitespace is ignored.

```text
# This is a comment
  # Indented comments are also valid
```

### 2.2 Global Directives
Global directives declare default attributes for all file entries in the manifest unless overridden on a specific file line. They must appear at the top of the file before any section headers.

Format: `DIRECTIVE_NAME: value`

* `DEFAULT_STD:` Sets the default language standard (`1993`, `2008`, `2019`). Default if omitted: `2008`.
* `DEFAULT_LIB:` Sets the default VHDL target library (`work`, `my_ip_lib`). Default if omitted: `work`.

```text
DEFAULT_STD: 2019
DEFAULT_LIB: axi_monitor_lib
```

### 2.3 Section Headers (Agnostic Sections)
Section headers group files by their role in the design. A section header is enclosed in square brackets `[...]`.

* Section names are **arbitrary string tags** (case-insensitive).
* A section header sets the active group for all subsequent lines until another header or EOF.
* Standard conventions include:
  * `[rtl]` — Synthesisable source files.
  * `[top]` — Top-level synthesis wrappers and register slices.
  * `[tb]` or `[tb:<name>]` — Verification testbenches and simulation models.
  * `[constraints]` — Timing (`.xdc`, `.sdc`) and pinout files.
  * `[sw]` — Embedded software / driver files.

```text
[rtl]
# Files here belong to the 'rtl' section

[tb]
# Files here belong to the 'tb' section
```

### 2.4 File Entry Lines & Attributes
A file entry consists of a relative file path followed by zero or more optional `key=value` attribute pairs separated by spaces.

Format: `<relative_file_path> [attr1=val1 attr2=val2 ...]`

* **Token 0 (`relative_file_path`):** File path relative to the directory containing this `.f` file.
* **Attributes (`key=value`):** Optional metadata overrides.

#### Attribute Reference Table

| Attribute | Description | Example Values | Default if Omitted |
| :--- | :--- | :--- | :--- |
| `std=` | Overrides the language standard for this line. | `1993`, `2008`, `2019` | Inherits `DEFAULT_STD` |
| `lib=` | Overrides the target VHDL compile library. | `common_lib`, `uvvm_util` | Inherits `DEFAULT_LIB` |
| `tb_top=` | Declares an executable testbench top-level entity name. | `tb_axi_monitor_reg` | Filename without extension |
| `feature=` | Feature tags required by this file (e.g., methodology). | `uvvm`, `psl`, `osvvm` | None |
| `tool=` | Comma-separated target tool filters (supports comparison operators). | `questa`, `vivado`, `tool=!xsim`, `tool="vivado>=2024.1"` | Valid for all tools |
| `exact_std=` | Disables automatic language standard promotion when set to `true`. | `true`, `false` | `false` |

```text
# Examples of File Entries
common/rtl/util_pkg.vhd             lib=common_lib
vendor/rtl/fifo_core.vhd            std=2008
legacy_ip/rtl/old_decoder.vhd       std=1993 exact_std=true lib=legacy_lib
axi_monitor/tb/axi_monitor_tb.vhd   tb_top=tb_axi_monitor_main feature=uvvm
```

### 2.5 Include Directives
An `include` statement recursively imports files from another `.f` file.

Format: `include <path_to_f_file> [<section_name>] [attribute_overrides...]`

* **`path_to_f_file`:** Path to the target `.f` file (relative to current `.f` file).
* **`[section_name]` (Optional):** Scopes the import to a specific section inside the target `.f` file (e.g., `[rtl]`). If omitted, inherits the current active section.
* **`attribute_overrides` (Optional):** Forces all imported files in that include to adopt specific attributes.

```text
# Include only the [rtl] section of axis_fifo:
include ../axis_fifo/vhdl.f [rtl]

# Include [rtl] of sub_ip and force all imported files to compile as std=2019:
include ../sub_ip/vhdl.f [rtl] std=2019
```

---

## 3. Tool Runner & Execution Rules

Build scripts processing this format must implement the following core algorithms:

### 3.1 Path Resolution (Anchoring)
When an `include` or file path is encountered, the path **must** be converted immediately to an absolute path anchored to the folder containing the `.f` file currently being read.

```text
File A (/repo/ip/top/vhdl.f):      include ../sub/vhdl.f
File B (/repo/ip/sub/vhdl.f):      rtl/pkg.vhd
Resolved Path:                     /repo/ip/sub/rtl/pkg.vhd
```

### 3.2 File Deduplication (Diamond Dependency Rule)
The runner must maintain a global set of visited absolute file paths. If a file is encountered multiple times (e.g., shared dependencies included by multiple sub-modules), **only the first occurrence is kept** to preserve compile order and prevent re-definition errors.

### 3.3 Library Creation & Mapping
Before compiling any source code, the runner must extract all unique `lib=` names across all resolved files and generate library initialization commands (e.g., `vlib <lib>; vmap <lib> ./<lib>`) prior to launching compilation.

### 3.4 Language Standard Promotion
If a top-level design or simulator target (such as Questa) requires VHDL-2019 globally, files marked `std=2008` or `std=1993` are automatically promoted to compile as `-2019` unless marked with `exact_std=true`.

### 3.5 Feature Compatibility Matching
Tool capability is evaluated using unified feature sets (e.g., `{"vhdl-2019", "uvvm", "psl"}`). If a file or testbench requires a feature tag not supported by the target tool (e.g., `feature=uvvm` on XSim), the runner will either:
* **Skip** the testbench if running full regression (`--tb all`).
* **Abort with a clear error** if the user explicitly requested that testbench.

---

## 4. Comprehensive Manifest Examples

### 4.1 Simple Standalone IP (`ip/axilite_io/vhdl.f`)

```text
# ============================================================================
# vhdl.f -- axilite_io IP Manifest
# ============================================================================
DEFAULT_STD: 2008
DEFAULT_LIB: axilite_io_lib

[rtl]
rtl/axilite_io_pkg.vhd
rtl/axilite_io_s.vhd
rtl/axilite_io.vhd

[tb]
# Testbench entity defaults to 'axilite_io_tb' (matching filename)
tb/axilite_io_tb.vhd
```

---

### 4.2 Shared Verification Model (`ip/jitter_gen/vhdl.f`)

```text
# ============================================================================
# vhdl.f -- jitter_gen Verification IP Manifest
# ============================================================================
DEFAULT_STD: 2019
DEFAULT_LIB: jitter_gen_lib

[rtl]
rtl/jitter_gen_pkg.vhd
rtl/jitter_gen.vhd

[tb]
# Standalone unit testbench for this verification IP
tb/jitter_gen_tb.vhd   tb_top=tb_jitter_gen_unit
```

---

### 4.3 Advanced Complex IP Manifest (`ip/axi_monitor/vhdl.f`)

```text
# ============================================================================
# vhdl.f -- axi_monitor Core IP & Verification Manifest
# ============================================================================
DEFAULT_STD: 2019
DEFAULT_LIB: axi_monitor_lib

# ----------------------------------------------------------------------------
# Synthesis RTL & Dependencies
# ----------------------------------------------------------------------------
[rtl]
# Include sub-dependencies (only their RTL sections)
include ../common_pkg/vhdl.f [rtl]         lib=common_lib
include ../axis_fifo/vhdl.f [rtl]           lib=axis_fifo_lib
include ../parallel_prng/vhdl.f [rtl]

# Legacy VHDL-93 file that cannot be promoted to 2019 due to reserved keywords
legacy/rtl/old_decoder.vhd                 std=1993 exact_std=true lib=legacy_lib

# Core axi_monitor RTL
rtl/axi_monitor_pkg.vhd
rtl/axi_monitor_ar.vhd
rtl/axi_monitor_r.vhd
rtl/axi_monitor.vhd

# ----------------------------------------------------------------------------
# Synthesis Wrappers
# ----------------------------------------------------------------------------
[top]
rtl/axi_monitor_top.vhd

# ----------------------------------------------------------------------------
# Testbenches & Simulation Models
# ----------------------------------------------------------------------------
[tb]
# Include verification models needed for simulation
include ../jitter_gen/vhdl.f [rtl]
include ../axi_mem_model/vhdl.f [rtl]

# Testbench 1: Simple Register Testbench (Runs on ALL simulators including XSim)
tb/axi_monitor_reg_tb.vhd                  tb_top=tb_axi_monitor_reg

# Testbench 2: Full UVVM Verification Testbench (Requires UVVM feature)
include ../uvvm_util/vhdl.f [tb]           feature=uvvm lib=uvvm_util
include ../bitvis_vip_sbi/vhdl.f [tb]      feature=uvvm lib=bitvis_vip_sbi
tb/axi_monitor_uvvm_tb.vhd                 feature=uvvm tb_top=tb_axi_monitor_uvvm_main

# ----------------------------------------------------------------------------
# Synthesis Constraints
# ----------------------------------------------------------------------------
[constraints]
constraints/axi_monitor_timing.xdc         tool=vivado
```