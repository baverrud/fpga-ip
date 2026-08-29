# hdltool

`hdltool` is the standalone HDL formatter and Vivado wrapper-discovery tool for
this repository. It supports VHDL (`.vhd`, `.vhdl`) and SystemVerilog (`.v`,
`.sv`). The formatter changes whitespace only and verifies that non-whitespace
tokens are preserved.

Wrapper analysis, VHDL shim/top generation, and the all-profile workflow are
implemented.

## Features

- Format VHDL and SystemVerilog while preserving all non-whitespace tokens.
- Analyze Vivado-generated VHDL wrappers and classify AXI, non-AXI, and flat ports.
- Create a compact, editable `name_map.json` with ignore rules and pattern groups.
- Discover wrappers and block designs from a Vivado project.
- Generate flat, signal-array, mode-view, and mode-view-array VHDL shims.
- Generate matching zero-port top-level shells for every shim profile.
- Use constrained AXI record subtypes and deterministic signal ordering.
- Run from the repository launcher or directly with Python.

## Typical Workflow

For the usual wrapper-to-shim workflow, only three commands are needed. Run
them from a Vivado project directory containing one project and one generated
wrapper:

1. Analyze the wrapper and create `name_map.json`:

  ```powershell
  hdltool analyze-wrapper
  ```

2. Edit `name_map.json` to adjust names, ignored ports, indexed groups, or
  mode-view interfaces.

3. Generate all shim and top-level variants:

  ```powershell
  hdltool generate-all
  ```

The generated files are written to the current directory by default. The
workflow produces `ps_flat`, `ps_slv_array`, `ps_mode_view`, and
`ps_mode_view_array` shims, each with a matching `_top` shell. No path,
`--name-map`, or `--outdir` option is needed for this common case.

## Installation

The repository launcher, relative to the `fpga-ip` repository root, is:

```text
hdltool.bat
```

From the `fpga-ip` repository root, invoke the launcher or run the Python
script directly:

```powershell
.\hdltool.bat --version
python .\tools\hdltool.py --version
```

Check the installed tool and available commands:

```text
hdltool --version
hdltool --help
```

## Formatting Files

Format one or more files in place:

```text
hdltool format path\to\file.vhd
hdltool format path\to\file.sv
```

A file path without the `format` operation is also accepted:

```text
hdltool path\to\file.vhd
```

A directory is searched recursively for `.v`, `.sv`, `.vhd`, and `.vhdl` files.
Common generated directories are skipped, including `.cache`, `.gen`, `.srcs`,
`.runs`, `.hw`, `.sim`, `sim`, `vivado`, and `work`:

```text
hdltool format . --style moderate
```

## Formatting Styles

Select a style with `--style` or `-s`:

| Style | Use |
| --- | --- |
| `moderate` | Default; aligns useful outer columns while keeping expressions natural. |
| `extreme` | Aligns inner ranges, assignments, punctuation, and comments. |
| `collapsed` | Uses compact spacing while preserving indentation and blank lines. |

Set the indentation width with `--indent` or `-i`:

```text
hdltool format file.vhd --style extreme --indent 4
```

Language is selected from the file extension. For stdin, `hdltool` uses a
content heuristic because stdin has no filename.

Markdown files are processed only inside fenced blocks tagged `vhdl`,
`systemverilog`, or `verilog`. Other Markdown content is left unchanged.

The formatter changes whitespace and blank lines only. Before writing a file,
it verifies that the sequence of non-whitespace characters is unchanged. If
that safety check fails, the file is not written.

Format piped input by omitting the input path:

```powershell
Get-Content -Raw .\input.vhd | hdltool format > .\output.vhd
```

Use `--check` to validate formatting without modifying files. It reports files
that can be processed safely and returns a nonzero status if formatting safety
fails:

```text
hdltool format path\to\file.vhd --check
hdltool format . --check
```

For a preview without writing, pipe the source to a separate output file or
use version control to inspect the whitespace-only diff after formatting.

## Analyze a Wrapper

Analyze a Vivado-generated VHDL wrapper before generating a shim:

```text
hdltool analyze-wrapper path\to\design_1_wrapper.vhd
hdltool analyze-wrapper path\to\design_1_wrapper.vhd path\to\analysis.json
hdltool analyze-wrapper path\to\design_1_wrapper.vhd --name-map path\to\name_map.json
hdltool generate-all path\to\design_1_wrapper.vhd --outdir path\to\generated
hdltool analyze-wrapper path\to\design_1_wrapper.vhd --analysis path\to\analysis.json
```

When run inside a Vivado project directory containing exactly one `.xpr` and
one existing referenced wrapper, the wrapper path can be omitted:

```text
cd path\to\vivado-project
hdltool analyze-wrapper
```

This writes `name_map.json` in the current directory. Use `--name-map PATH` to
choose a different mapping-file path.

Generation uses `name_map.json` from the current directory by default when it
exists, then falls back to a map beside the wrapper. Generated files are
written to the current directory unless `--outdir` is supplied. The default
formatting style is `moderate`.

`analyze-wrapper` prints the same small mapping-only JSON that `--name-map` writes.
The complete analysis remains in memory for the current command. Use
`--analysis`, or the legacy second positional output path, only when the full
diagnostic dictionary is needed. The mapping result contains exact entries and
compact patterns:

```json
{
  "_ignore"    : ["DDR*", "FIXED_IO_*"],
  "_non_indexable" : {
    "pl_clk[]"  : "ps_clk[]"
  },
  "_interfaces" : {
    "M[]_AXI_0" : "axilite[]"
  },
  "_indexable" : {
    "SPI_[]_0"  : "spi[]"
  }
}
```

Patterns in `_indexable` are aggregated by non-flat generation profiles.
Patterns in `_non_indexable` remain separate. The `flat` profile ignores this
grouping distinction.
Mappings in `_interfaces` identify AXI buses eligible for the mode-view and
mode-view-array profiles. Interface mappings are also indexable by default.
When `_interfaces` is absent, all recognized AXI buses retain the legacy
mode-view behavior.

`_ignore` is an optional list of case-insensitive glob patterns. Matching
wrapper ports are intentionally omitted from generated shim/top interfaces and
wrapper associations. For example, `DDR*` and `FIXED_IO_*` ignore Zynq-7000
board-level artifacts without assigning them generated signal names. `DDR*`
also covers the analyzer's exact `DDR` bus-group key. Ignoring a port does not
modify the original Vivado wrapper.

The persisted mapping file uses compact pattern entries for repeated
interfaces. Non-clock interfaces belong in `_indexable`:

```json
"_indexable": {
  "M[]_AXI_0": "axilite[]",
  "S_AXI_HP[]_FPD_0": "hp[]",
  "SPI_[]_0": "spi[]",
  "IIC_[]_0": "i2c[]",
  "pl_resetn[]": "ps_srstn[]"
}
```

`[]` captures a numeric index and removes leading zeroes. A pattern without
`*` is treated as an interface-prefix mapping, so the unmatched signal suffix
is preserved automatically. Signals without an exact or pattern mapping keep
their original names by default. Exact entries may be added beside the pattern
groups for signals that need an exception. For example, `SPI_0_0_sck_io` becomes
`spi0_sck_io`, while `SPI_1_0_sck_io` becomes `spi1_sck_io`.

When a peripheral family has both an unsuffixed and an extra-indexed Vivado
group, the analyzer preserves that distinction without assigning PS/PL
semantics:

```json
"IIC_[]"   : "i2c[]",
"IIC_[]_0" : "i2c[]_0"
```

Thus `IIC_0_scl_io` becomes `i2c0_scl_io`, while `IIC_0_0_scl_io` becomes
`i2c0_0_scl_io`. Edit these patterns to add `ps_` or `pl_` after checking the
block-design connections. Families present in only one form keep their simple
names.

An indexed replacement may use `[N]` to add an offset to the captured index.
For example:

```json
"gpio_rtl_[]": "gpio[2]"
```

maps `gpio_rtl_0_tri_io` to `gpio2_tri_io` and
`gpio_rtl_1_tri_io` to `gpio3_tri_io`. The brackets in `[2]` are mapping
syntax; they are not emitted as brackets in the VHDL identifier.

The optional `*` form is reserved for an explicit full-signal pattern, such as
`SPI_[]_0_*` to `spi[]_*`. It is not needed for normal bus mappings.

`master_names` contains only AXI buses identified as masters. Prefixes starting
with `M_` or `M` followed by digits are classified as masters; prefixes starting
with `S_` are classified as slaves. The dictionary is the intermediate input
for shim generation. After hand editing the file, use `generate-shim` with
`--name-map path\to\name_map.json`.

During shim generation, the analyzer supplies the bus index separately from the
name mapping. A multi-bit signal therefore maps without a signal index:

```vhdl
M00_AXI_0_awaddr => axilite_arr(0).awaddr,
M01_AXI_0_awaddr => axilite_arr(1).awaddr,
```

Only a collapsed one-bit wrapper vector uses `(0)` on the wrapper side:

```vhdl
M00_AXI_0_awvalid(0) => axilite_arr(0).awvalid,
```

This distinction belongs to shim generation, not to the hand-edited mapping.

The complete analysis still groups indexed interfaces in memory under
`master_arrays` and `peripheral_arrays`; the mapping file contains only the
editable mappings and patterns, not the full port analysis.

## Generate Shim Variants

Generate all four VHDL shim variants and their matching synthesis tops with one
command:

```text
hdltool generate-all path\to\design_1_wrapper.vhd --outdir path\to\generated
```

When the current directory contains exactly one wrapper, the wrapper path may
be omitted. The command then uses the current directory for generated files by
default:

```text
cd path\to\vivado-project
hdltool generate-all
```

This writes eight files:

```text
ps_flat.vhd
ps_flat_top.vhd
ps_slv_array.vhd
ps_slv_array_top.vhd
ps_mode_view.vhd
ps_mode_view_top.vhd
ps_mode_view_array.vhd
ps_mode_view_array_top.vhd
```

Generate one selected pair with `--profile`:

```text
hdltool generate-shim path\to\design_1_wrapper.vhd --profile slv-array --outdir generated
```

All generated files use the default prefix `ps_`. Override it with
`--prefix`, for example `--prefix custom_`, which produces `custom_flat.vhd`
and `custom_flat_top.vhd`.

The profiles are:

| Profile | Indexed interface form |
| --- | --- |
| `flat` | Individual mapped signals such as `axilite0_awaddr` |
| `slv-array` | Descending arrays; vectors use `slv_array_t(1 downto 0)(31 downto 0)` and one-bit signals use `std_logic_vector(1 downto 0)` |
| `mode-view` | One scalar AXI record mode view per selected bus; mapped indexable flat ports are arrays |
| `mode-view-array` | Arrays of VHDL-2019 mode-view records where package types exist; mapped indexable flat ports are also arrays |

Each top is a zero-port synthesis shell. It declares internal signals matching
its shim profile and instantiates the corresponding shim. The `slv-array`
profile uses `M00_AXI_0_awaddr => axilite_awaddr(0)`. One-bit repeated signals
use a single vector index, for example `hp_awvalid(0)`. The record-array profile
uses `M00_AXI_0_awaddr => axilite(0).awaddr`. Only collapsed one-bit wrapper
vectors use `(0)` on the wrapper side.

Pass a hand-edited mapping file to generation with `--name-map`; unmatched
signals retain their original names:

```text
hdltool generate-all wrapper.vhd --name-map name_map.json --outdir generated
```

Generated friendly names omit redundant trailing Vivado interface suffixes:
`_tri_io`, `_io`, `_i`, and `_o`; UART `rxd`/`txd` names become `rx`/`tx`.
For example, `gpio0_tri_io` becomes `gpio0` and `i2c0_scl_io` becomes
`i2c0_scl`. The wrapper-side names in port associations remain unchanged.

SystemVerilog generation is reserved for a later increment.

For PYNQ-Z2 and other Zynq-7000 wrapper inputs, generated shims and tops omit
`DDR_*` and `FIXED_IO_*` board-level ports. These Vivado wrapper artifacts are
not exposed by the shim and are left unassociated in the wrapper instantiation;
the original generated wrapper file is never modified.

The analyzer determines AXI protocol from the wrapper signal set. A bus with
AXI4-only fields such as `awqos`, `awregion`, `awburst`, or `awlen` is named
`axi[]`, even if Vivado calls its prefix `M00_AXI_0`. A true AXI-Lite bus is
named `axilite[]`. If an older hand-edited map still contains
`"M[]_AXI_0": "axilite[]"` for a full AXI4 wrapper, generation stops with a
protocol-mismatch error. Regenerate that map or change the entry to
`"M[]_AXI_0": "axi[]"`.

## Pipe Input to Output

When no input path is supplied, `hdltool format` reads stdin and writes
formatted HDL to stdout. In Command Prompt, redirect the output to a separate
file:

```cmd
type input.vhd | hdltool format > output.vhd
```

The same Command Prompt command works from PowerShell and safely handles paths
containing spaces when quoted:

```powershell
cmd /c 'type "input file.vhd" | hdltool format > "output file.vhd"'
```

PowerShell 7 or newer can use its native pipeline and explicit UTF-8 output:

```powershell
Get-Content -Raw .\input.vhd | hdltool format | Set-Content -Encoding utf8NoBOM .\output.vhd
```

Use the repository-relative launcher when `hdltool` is not on `PATH`:

```cmd
type input.vhd | .\hdltool.bat format > output.vhd
```

Do not use `--check` when creating an output file. `--check` reads and
analyzes the input, but does not write formatted output:

```cmd
type input.vhd | hdltool format --check
```

## Check Mode

Check that files can be read and processed safely without modifying them:

```text
hdltool format path\to\file.vhd --check
hdltool format path\to\file.sv --check
hdltool format . --check
```

Check mode verifies formatter safety and token preservation. It is not a
language compiler and does not replace VHDL or SystemVerilog syntax checking
with Questa, ModelSim, Vivado, or another HDL tool.

## Wrapper Discovery

Search a Vivado project from its `.xpr` file or from a directory containing
exactly one `.xpr` file:

```text
hdltool search-wrappers path\to\project.xpr
hdltool search-wrappers path\to\project-directory
```

When no project argument is supplied, the current directory is searched:

```text
cd path\to\project-directory
hdltool search-wrappers
```

The command reports generated wrapper files, their matching `.bd` sources,
missing wrappers, and unrelated block designs found by the supplemental scan.
The `.xpr` relationship is authoritative; generated synthesis-run Tcl files are
not treated as block-design source files.

## Command Summary

```text
hdltool format [file-or-directory ...] [options]
hdltool analyze-wrapper [paths ...]
hdltool search-wrappers [project.xpr|project-directory]
hdltool generate-shim [paths ...]
hdltool generate-top [paths ...]
hdltool generate-all [paths ...]
```

`analyze-wrapper` is implemented and produces the compact mapping by default. Use
`--analysis` when the full intermediate wrapper dictionary is needed.
`generate-shim`, `generate-top`, and `generate-all` generate VHDL shim/top
pairs using the selected profile or all four profiles.

Common options:

```text
--style, -s {extreme,moderate,collapsed}
--indent, -i WIDTH
--check, -c
--name-map PATH
--analysis PATH
--version
```

## Exit Status

| Status | Meaning |
| --- | --- |
| `0` | Input was processed successfully. |
| `1` | Wrapper discovery found missing wrappers. |
| `2` | Input path, command, or processing error. |
| `3` | Formatter token-safety check failed. |
