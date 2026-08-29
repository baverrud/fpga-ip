# toolchains.ini (Specification)

> How `run.py` finds and sets up your installed EDA tools on this machine.
> This is a **local, machine-specific** file - it is gitignored on purpose.
>
> **Related documents**
> - [README](../README.md) - repository overview and quick start
> - [User Manual](user-manual.md) - environment requirements
> - [.f Manifest Format](f-manifest-spec.md) - the `.f` file format
> - [tool_capabilities.ini](tool-capabilities-spec.md) - what tools *provide*
>   (this file is about how to *reach* them)

---

## What It Is

`toolchains.ini` maps a logical tool name (and optionally a version) to a
shell command that prepares that tool's environment - usually a launcher
batch file that sets `PATH` and the tool's ini variables.

The file is **not committed**. It is machine-specific by design: launcher
names and installation paths differ per machine. A template is provided as
[`toolchains.ini.example`](../toolchains.ini.example).

## Where `run.py` Looks for It

Lookup precedence:

1. The file named by `FPGA_IP_TOOLCHAINS`.
2. Ignored repository-local `toolchains.ini` in the repository root.
3. `%APPDATA%/fpga-ip/toolchains.ini` on Windows.
4. `~/.config/fpga-ip/toolchains.ini` on other systems.
5. The current process environment if no registry is available.

## File Format

One base or version-qualified section per logical tool:

### Smallest useful setup

If only one simulator is installed, one base section is enough:

```ini
[toolchain.modelsim]
setup = <command-that-activates-modelsim>
```

`run axis_fifo vhdl modelsim` executes the setup command in a child shell,
probes the resulting `vsim`, and uses that same environment for compilation
and simulation.

### Versioned multi-tool setup

```ini
[toolchain.modelsim]
setup = <command-that-activates-modelsim>

[toolchain.questa]
setup = <command-that-activates-questa>

[toolchain.vivado.2023.2]
setup = <command-for-vivado-2023.2>

[toolchain.vivado.2025.2]
setup = <command-for-vivado-2025.2>

[toolchain.xsim.2025.2]
setup = <command-for-vivado-2025.2>
```

When `run.py` receives `vivado --version 2025.2`, it selects
`[toolchain.vivado.2025.2]`, executes its `setup` command in a child shell,
captures the resulting `PATH` and tool variables, and uses that environment
for both `vivado -version` probing and synthesis. XSim normally shares the
corresponding Vivado setup.

The setup changes only child processes; it does not change the parent
PowerShell or CMD session. Single-target output prints the selected setup and
the detected tool identity, for example:

```text
toolchain: <configured setup command>
detected  : questa 2025.3 / starter
```

### Selecting a Version

When several versions are registered, the command's `--version` chooses the
matching section:

```text
run axis_fifo vhdl vivado --version 2023.2
run axis_fifo vhdl vivado --version 2025.2
run axis_fifo vhdl questa --version 2025.3
```

If the setup command produces a different version than requested, `run.py`
stops with a version mismatch instead of silently using the wrong tool.

## How `run.py` Captures the Environment (and a Pitfall)

On Windows, `run.py` runs the `setup` command inside a fresh child CMD and
then parses that shell's `set` output to build the child environment used for
the tool:

1. It starts from a copy of the current parent environment.
2. It overlays every variable that appears in the child's `set` output.
3. **A variable that the setup *clears* disappears from `set` output** - so
   the runner does not know to remove it from its copy.

Consequence: if the parent environment already has a variable that the
launcher clears (for example, a ModelSim `MODELSIM` ini when switching to
Questa), the stale value survives into the tool run.

**Example pitfall (fixed in run.py):** ModelSim sets `MODELSIM` and clears
`QSIM_INI`; Questa sets `QSIM_INI` and clears `MODELSIM`. If a Questa run
inherited a leftover `MODELSIM` pointing at a ModelSim ini, Questa would
report that precompiled UVVM packages need recompiling (`std.env has
changed`) and fail. `run.py` therefore strips an inherited `MODELSIM`
whenever a Questa setup provides `QSIM_INI`.

## See Also

- [User Manual](user-manual.md)
- [tool_capabilities.ini](tool-capabilities-spec.md)
