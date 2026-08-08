# Repository Tools

Repository-wide utilities live here. These tools are not part of an IP core
and do not belong in an individual IP directory.

## HDL Formatter

[`hdl-formatter.py`](../tools/hdl-formatter.py) is a whitespace-only formatter for VHDL
and SystemVerilog. It formats synthesis wrappers and VHDL/SystemVerilog code
blocks in README files. It never changes the non-whitespace token stream.

Run it from the fpga-ip repository root:

```text
python tools/hdl-formatter.py <file> [<file> ...]
```

### Styles

| Style | Behavior |
|-------|----------|
| `moderate` | Default. Aligns useful outer columns while keeping ranges, values, and punctuation natural. |
| `extreme` | Aligns inner range values, assignments, punctuation, and comments for template-heavy blocks. |
| `collapsed` | Removes block-wide padding while preserving indentation and logical blank lines. |

Select a style explicitly with `--style`:

```text
python tools/hdl-formatter.py --style moderate axi_monitor/rtl/axi_monitor_top.vhd
python tools/hdl-formatter.py --style extreme axi_monitor/README.md
python tools/hdl-formatter.py --style collapsed axi_monitor/rtl/axi_monitor_top.sv
```

Markdown files are processed only inside fenced blocks tagged `vhdl`,
`systemverilog`, or `verilog`. Other Markdown content is left unchanged.

### Options

- `--check` reports files that would change and never writes them. It exits
  with status 1 when formatting is needed.
- `--dry-run` prints a unified diff without writing files.
- `--stdin` reads a raw HDL block from standard input and writes formatted HDL
  to standard output.
- `--lang {vhdl,sv,auto}` selects the language for stdin or raw files.
- `--no-collapse-blank` preserves runs of blank lines instead of reducing them
  to one blank line.

### Safe Workflow

Preview changes before writing them:

```text
python tools/hdl-formatter.py --style moderate --dry-run path/to/file.vhd
```

Use `--check` in validation scripts after formatting is applied:

```text
python tools/hdl-formatter.py --check path/to/file.vhd path/to/file.sv
```

The formatter performs an invariant check before writing. If the sequence of
non-whitespace characters changes, it refuses to write the file.
