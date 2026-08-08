# tool_capabilities.ini (Specification)

> **Status:** Authoritative - this is the only specification.
>
> `tool_capabilities.ini` records what each EDA tool actually provides in a
> given environment, so `run.py` can decide **before compilation** whether a
> selected target can run on a selected tool.
>
> **Related documents**
> - [README](../README.md) - repository overview and quick start
> - [User Manual](user-manual.md) - how targets are run
> - [.f Manifest Format](f-manifest-spec.md) - how a target declares what it
>   `requires`
> - [toolchains.ini](toolchains-spec.md) - machine-local tool setup

---

## The Idea in One Sentence

- A `.f` manifest declares what a target **requires**.
- `tool_capabilities.ini` declares what a tool **provides**.
- The runner compares the two and runs, skips, or fails with a clear message.

The file lives at the repository root next to `run.bat` (it is configuration
consumed by the runner, not a doc). It is machine-parsed, so keep it free of
prose and tables. Comments start with `;` or `#`. Encoding is ASCII-only.

---

## 1. Required Section Order

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

---

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

### 2.1 Partial Language Support

`vhdl-2019` is a **coarse** token: a tool claims only the subsets it
verifiably supports. No tool is assumed to implement the whole standard.
Subset tokens (e.g. `vhdl-2019-interfaces`) must be added to
`allowed_features` and declared in the tool profile before use in a manifest.
Constructs outside the declared subsets surface at compile time and fail
loudly - acceptable, because the runner prevents silently running a tool known
to lack a needed subset.

---

## 3. `[defaults]`

Most tools share a common feature set. A single `[defaults]` section declares
the baseline that every tool inherits:

```ini
[defaults]
features = vhdl-93,vhdl-2002,vhdl-2008,verilog,systemverilog
```

---

## 4. Tool Profiles

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

---

## 5. Current Profiles

### Smallest useful configuration

For a local tool that supports VHDL-2008 and UVVM, the minimum profile is:

```ini
[features]
allowed_features = vhdl-2008,uvvm

[defaults]
features = vhdl-2008

[tool.my_sim]
probe = vsim -version
modes = batch,gui
features = +uvvm
```

The `requires = uvvm` line in a manifest can now match `my_sim`, while an
unknown token such as `requires = uvvm2` is rejected.

### Layered version and edition profiles

Profiles are applied in file order. A common pattern is a base profile with
shared capabilities, followed by a version profile that adds a newer
language standard and an edition profile that pins the exact installation:

```ini
[tool.my_sim]
probe = vsim -version
version_re = vsim\s+(\d+\.\d+)
edition_re = Example\s+(Starter)\s+Edition
modes = batch,gui,project
features = +uvvm

[tool.my_sim.2025.3]
features = +vhdl-2019

[tool.my_sim.2025.3.starter]
features =
```

The final empty `features =` does not reset earlier features; it only makes
the exact version/edition combination matchable.

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

---

## 6. Adding or Editing a Tool

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

---

## 7. Relationship to the `.f` Manifest

The `.f` manifest's testbench `requires` values and the VHDL standards used
in the manifest are compared against the selected tool's effective feature
set:

- VHDL standards map to features: `1993`->`vhdl-93`, `2002`->`vhdl-2002`,
  `2008`->`vhdl-2008`, `2019`->`vhdl-2019`.
- A missing capability for an explicitly selected testbench produces a
  WARNING (exit code 3) or a skip for XSim; in a sweep it produces a `SKIP`
  row with a reason.

---

## 8. Runner Tests

The parser and capability layer have a dependency-free regression suite:

```text
python -m unittest discover -s tests -v
```

These tests do not require an EDA installation. They cover manifest parsing,
source existence, section normalization, duplicate-source handling, invalid
attributes, library validation, and tool identity probing. EDA simulations
remain the authoritative backend validation.

### Capability Decision Examples

Given this manifest section:

```text
[tb:uvvm]
top = my_ip_uvvm_tb
requires = uvvm
```

- ModelSim and Questa run it when their effective features include `uvvm`.
- XSim skips it because its profile does not provide `uvvm`.
- A tool without a matching profile is rejected before compilation.
- A typo such as `requires = uvvvm` is a manifest validation error, not a
  capability mismatch.

---

## See Also

- [User Manual](user-manual.md)
- [.f Manifest Format](f-manifest-spec.md)
- [toolchains.ini](toolchains-spec.md) - the machine-local setup that points
  `probe`/`setup` commands at installed tools
