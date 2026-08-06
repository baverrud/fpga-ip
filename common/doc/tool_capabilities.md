# Tool Capabilities

**Document Title:** `tool_capabilities.ini` - Specification and User Guide
**Status:** Proposed
**Target Domain:** FPGA and mixed-language IP repositories

This document is both the reference specification and the user guide for the
tool capabilities file. It explains what the file does, how to read it, how to
edit it, and how the runner uses it.

---

## Table of Contents

1. [What This File Does](#1-what-this-file-does)
2. [File Location and Format](#2-file-location-and-format)
3. [Quick Start](#3-quick-start)
4. [Feature Vocabulary](#4-feature-vocabulary)
5. [Baseline and Effective Feature Set](#5-baseline-and-effective-feature-set)
6. [Tool Profiles and Version Matching](#6-tool-profiles-and-version-matching)
7. [Editions](#7-editions)
8. [Operational Metadata](#8-operational-metadata)
9. [Environment-Sensitive Features](#9-environment-sensitive-features)
10. [Runner Algorithm](#10-runner-algorithm)
11. [Validation Rules](#11-validation-rules)
12. [Relationship to the `.f` Manifest](#12-relationship-to-the-f-manifest)
13. [Troubleshooting](#13-troubleshooting)
14. [Open Questions](#14-open-questions)

---

## 1. What This File Does

The tool capabilities file records what each EDA tool actually provides in a
given repository and environment. It lets the runner decide, before
compilation, whether a selected target can run on a selected tool.

The file keeps tool knowledge out of the `.f` manifests:

- A `.f` manifest declares what a target **requires**.
- `tool_capabilities.ini` declares what a tool **provides**.
- The runner compares the two and either runs, skips, or fails with a clear
  message.

Example outcome:

```text
run axis_fifo vhdl modelsim --tb uvvm
  tool:      modelsim 2020.1 (starter)
  provides:  vhdl-93, vhdl-2008, verilog, systemverilog
  requires:  vhdl-2008, uvvm
  result:    SKIP - feature 'uvvm' not provided by this tool/environment
```

## 2. File Location and Format

- **File name:** `tool_capabilities.ini`
- **Location:** the fpga-ip repository root, next to `run.bat`/`run.sh`. It is
  configuration consumed by the runner, so it lives at the repo root, not
  under `common/doc/`. The human-readable guide is
  `common/doc/tool_capabilities.md`.
- **Format:** structured INI. It is machine-parsed, so avoid prose and tables
  inside the file itself.
- **Encoding:** UTF-8 without BOM, ASCII-only content so CMD, Tcl, and shell
  tooling can consume it.
- **Comments:** lines starting with `;` or `#`.

```ini
; tool_capabilities.ini - allowable features + per-tool capabilities
; This file is generated/edited by hand and validated at parse time.

[features]
allowed_features = vhdl-93,vhdl-2002,vhdl-2008,vhdl-2019,verilog,systemverilog,uvm,uvvm,osvvm
```

## 3. Quick Start

### Add a new tool

1. Keep `[features]` first and add new feature names to `allowed_features`.
2. Add a `[defaults]` section if it does not exist.
3. Add a versionless profile for the tool.
4. Add version-specific profiles when capabilities change between versions.
5. Add an edition profile when the edition changes behavior.

```ini
[features]
allowed_features = vhdl-93,vhdl-2002,vhdl-2008,vhdl-2019,verilog,systemverilog,uvm,uvvm,osvvm

[defaults]
features = vhdl-93,vhdl-2002,vhdl-2008,verilog,systemverilog

[tool.ghdl]
probe = ghdl --version
features = +vhdl-2019
```

### Add a new capability check to a testbench

```text
[tb:uvvm]
requires = +uvvm
```

The runner will compare `requires = {vhdl-2008, uvvm}` (inherited baseline plus
`uvvm`) against the selected tool's feature set.

### Define a new feature

The feature namespace is open-ended: you are free to add any feature you need.
The `allowed_features` value in the first `[features]` section is the
authoritative vocabulary. A feature must be declared consistently in three
places:

1. **`tool_capabilities.ini` `[features]`** - add `<feature>` to
  `allowed_features`.
2. **`tool_capabilities.ini` tool profiles** - add `+<feature>` to every
  profile that provides it.
3. **`.f` manifest** - add `requires = +<feature>` to every target that needs
  it.

Example - introduce a methodology `uvvm2`:

```text
# .f target
[tb:uvvm2]
requires = +vhdl-2008,+uvvm2
```

```ini
[features]
allowed_features = ...,uvvm2

[tool.questa.2025.3]
features = +uvvm2
```

Rules of thumb:

- Declare a feature only for tools that verifiably provide it (never add a
  library-dependent feature to the baseline just because one tool has it).
- A feature in the INI that nothing requires is harmless.
- A token not present in `allowed_features` is a probable typo and is rejected
  at parse time (section 4).
- A token present in `allowed_features` but provided by no matching tool is a
  valid feature name but a capability mismatch.
- A feature declared in the INI but only on tools that do not match the
  selection means the target is rejected or skipped for those tools - the
  runner is working as intended.

### Typical edit for a new simulator version

```ini
[tool.questa.2025.3]
features = +vhdl-2019
```

The versionless `[tool.questa]` profile is the fallback for unlisted versions.

## 4. Feature Vocabulary

There is no separate vocabulary file. The `allowed_features` value in the
first `[features]` section is the complete whitelist of legal feature names.
Tokens in `[defaults]`, tool profiles, and `.f` manifests must be in that
whitelist. A `-token` does not add a token to the whitelist.

Features use one flat namespace. Language standards, verification frameworks,
and methodologies are all features. The current allowable tokens are listed
below. The final row is illustrative and is not currently in `allowed_features`:

| Feature | Meaning |
| --- | --- |
| `vhdl-93` | VHDL-1993 compilation supported |
| `vhdl-2002` | VHDL-2002 compilation supported |
| `vhdl-2008` | VHDL-2008 compilation supported |
| `vhdl-2019` | VHDL-2019 compilation supported (coarse; see section 4.1) |
| `verilog` | Verilog compilation supported |
| `systemverilog` | SystemVerilog compilation supported |
| `uvm` | UVM (SystemVerilog verification) available |
| `uvvm` | UVVM (VHDL verification) libraries available |
| `osvvm` | OSVVM (VHDL verification) available |
| `my-custom-method` | Illustrative custom feature - add it to `allowed_features` before using it (section 3) |

The vocabulary is open-ended: add a new token to `allowed_features` before
using it. A token absent from that list fails at parse time as a probable typo,
for example `vhdl-209`. A token may be legal without being provided by the
selected tool.

### 4.1 Partial language support

`vhdl-2019` is a coarse token. No tool is assumed to implement the whole
standard; a tool claims only the subsets it verifiably supports. The example
subset token below is not currently in `allowed_features`; add it there and
declare it in a tool profile before using it in a real manifest.

- Coarse token: `vhdl-2019` - the tool compiles VHDL-2019 files (some subset).
- Subset token: `vhdl-2019-interfaces` - interface views / mode views.

Rules:

1. A target using VHDL-2019 declares the subset it needs, for example
   `requires = +vhdl-2019-interfaces`.
2. A tool declares only the subsets it verifiably supports. Unverified subsets
   are left out, so the runner rejects or skips the target instead of guessing.
3. Never upgrade `vhdl-2019` to mean full compliance.
4. Constructs outside the declared subsets surface at compile time and fail
   loudly. That is acceptable: the runner cannot prove every construct, but it
   prevents silently running a tool known to lack the needed subset.

Same tool, different subsets (illustrative - not the current configuration):

```ini
[tool.tool_a.2025.3]
features = +vhdl-2019,+vhdl-2019-interfaces

[tool.tool_b.2026.1]
features = +vhdl-2019        ; interfaces subset NOT declared
```

A target `requires = +vhdl-2019-interfaces` runs on tool A but is rejected
for tool B until that subset is verified there.

## 5. Baseline and Effective Feature Set

Most tools share a common feature set. Repeating it in every tool profile is
noise, so a single `[defaults]` section declares the baseline:

```ini
[defaults]
features = vhdl-93,vhdl-2002,vhdl-2008,verilog,systemverilog
```

Each tool profile modifies the baseline with `+` and `-` entries:

```ini
[tool.modelsim.2020.1]
features = +uvvm
```

### 5.1 Matching chain: how the effective set is built

The effective feature set is built by applying every matching profile in file
order. The required section order is:

```text
[features]
  -> [defaults]
  -> matching [tool.*] sections, top to bottom as written
```

The runner does not reorder profiles by specificity. The user must place
less-specific profiles before more-specific profiles:

```text
[defaults]
  -> [tool.<name>]
  -> [tool.<name>.<version>]
  -> [tool.<name>.<version>.<edition>]
```

Only profiles in this chain that exist for the selected tool are applied.
Profiles for other tools, or for other versions/editions of the same tool,
are never consulted.

The effective set is the ordered result of applying each delta:

```text
effective = defaults
            then +additions / -removals of each matching profile,
            in file order
```

Example for a Starter 2020.1 profile:

```ini
[defaults]
features = vhdl-93,vhdl-2002,vhdl-2008,verilog,systemverilog

[tool.modelsim]
features = +uvvm

[tool.modelsim.2020.1]
features = +osvvm

[tool.modelsim.2020.1.starter]
features = -uvvm
```

| Step | Delta | Effective set |
| --- | --- | --- |
| `[defaults]` | — | vhdl-93, vhdl-2002, vhdl-2008, verilog, systemverilog |
| `[tool.modelsim]` | +uvvm | ... + uvvm |
| `[tool.modelsim.2020.1]` | +osvvm | ... + osvvm |
| `[tool.modelsim.2020.1.starter]` | -uvvm | ... - uvvm |

Final effective set: `vhdl-93, vhdl-2008, verilog, systemverilog, osvvm`.

A `-feature` only has an effect when the feature was introduced by an earlier
matching profile in the file (for example `uvvm`). This is why file order is
the user's responsibility.

### 5.2 `+` and `-` semantics

- `+feature`: add the feature to the inherited set.
- `-feature`: remove the feature from the inherited set.
- A bare `feature` (no prefix) is treated as `+feature` for convenience.
- An empty `features =` is the identity delta: it adds and removes nothing, so
  the profile inherits the chain unchanged. It is used to pin an exact
  version/edition profile for lookup without changing features. It is never a
  reset that clears the inherited set.

The tool profile always inherits `[defaults]`. There is no implicit "all
features" baseline; everything is declared or derived from `[defaults]`.

`-feature` means "remove from the inherited set", not "the environment must
not have this feature".

### 5.3 Example - tools supported by this repository

```ini
[features]
allowed_features = vhdl-93,vhdl-2002,vhdl-2008,vhdl-2019,verilog,systemverilog,uvm,uvvm,osvvm

[defaults]
features = vhdl-93,vhdl-2002,vhdl-2008,verilog,systemverilog

; ModelSim 2020.1 (Intel FPGA Starter Edition) - no VHDL-2019
[tool.modelsim]
probe = vsim -version
version_re = vsim\s+(\d+\.\d+)
edition_re = INTEL\s+FPGA\s+(STARTER)\s+EDITION
modes = batch,gui,project
features = +uvvm

; versionless Starter pin: empty = identity delta (inherits +uvvm)
[tool.modelsim.starter]
features =

; version + edition profile: 2020.1 Starter (no extra features)
[tool.modelsim.2020.1.starter]
features =

; Questa 2025.3 - coarse VHDL-2019 only; interfaces subset NOT declared
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

Note: `modelsim` and `questa` both launch `vsim`, but they are different tool
names. `run.bat`/`run.sh` selects which tool name to use, so the profiles
remain independent.

## 6. Tool Profiles and Version Matching

Each tool profile is keyed as:

```ini
[tool.<name>.<version>]
```

An edition-qualified profile appends the edition:

```ini
[tool.<name>.<version>.<edition>]
```

Profiles are matched against the detected tool name, version, and edition, but
matching profiles are applied in the order written in the file. The full key
grammar - including the versionless and edition-only forms
(`[tool.<name>.<edition>]`, `[tool.<name>]`) - is in section 7.1.

A versionless profile matches other versions when its tool name matches:

```ini
[tool.modelsim]
features = +uvvm

[tool.modelsim.2020.1]
features = +uvvm
```

### 6.1 Version-of-versions: canonical version extraction

Tool version strings are not clean. For example:

```text
> vsim -version
Model Technology ModelSim - INTEL FPGA STARTER EDITION vsim 2020.1 Simulator 2020.02 Feb 28 2020
```

The raw string carries several version-like tokens:

| Token | Kind | Meaning |
| --- | --- | --- |
| `2020.1` | Product version | The version people write in profiles |
| `2020.02` | Build version | Internal engineering build, irrelevant for matching |
| `INTEL FPGA STARTER EDITION` | Edition | Affects licensing and features |

The runner must **never match profiles against the raw probe string**. Each
tool profile declares regexes that extract the canonical product version and
the edition:

```ini
[tool.modelsim]
probe = vsim -version
version_re = vsim\s+(\d+\.\d+)
edition_re = INTEL\s+FPGA\s+STARTER\s+EDITION
features = +uvvm
```

`version_re` captures `2020.1`. `edition_re` captures the edition, which is
normalized to lowercase with whitespace runs replaced by a single hyphen, so
`INTEL FPGA STARTER EDITION` becomes the profile token `starter`.

### 6.2 Version regex fallback

If `version_re` fails to match the probe output, version-constrained profiles
cannot match. The runner may use matching versionless profiles; otherwise it
reports an error including the raw probe output so the regex can be corrected.

A missing or ambiguous version must never be silently approximated with a
"closest" version, because that can select the wrong capabilities.

## 7. Editions

An edition is not cosmetic. Different editions of the same tool may have
different capabilities. Matching one edition to a profile intended for
another edition can silently over-advertise features such as `uvvm`.

### 7.1 Profile key grammar

The profile key is built from three identity parts: `<name>`, `<version>`,
and `<edition>`.

```text
[tool.<name>.<version>.<edition>]   ; full identity (name + version + edition)
[tool.<name>.<version>]             ; version only (other editions)
[tool.<name>.<edition>]             ; versionless profile for one edition
[tool.<name>]                       ; versionless, editionless baseline
```

This ordering matches how products are named: "ModelSim 2020.1 Starter
Edition" maps to `[tool.modelsim.2020.1.starter]`.

### 7.2 Profile matching

The runner considers all profiles that match the detected identity:

1. `[tool.<name>]` matches the tool name.
2. `[tool.<name>.<version>]` matches the tool name and version, for other
  editions unless a more specific edition profile changes the result.
3. `[tool.<name>.<edition>]` matches the tool name and edition.
4. `[tool.<name>.<version>.<edition>]` matches all three identity parts.

All matching profiles are applied from top to bottom in the file. There is no
implicit default-edition classification. An unrecognized edition is simply
another edition, and the user must provide or omit matching profiles knowingly.

Because the version itself may contain a dot (`2020.1`), keys are matched
whole against the set of known profiles. They are never split on dots to guess
boundaries.

### 7.3 Example - matching hierarchy

A single tool can have four stacked profiles, each narrowing the feature set:

```ini
[defaults]
features = vhdl-93,vhdl-2002,vhdl-2008,verilog,systemverilog

; 1. Name only - baseline fallback for any unlisted version/edition
[tool.modelsim]
features = +uvvm

; 2. Name + version - 2020.1 profile for other editions
[tool.modelsim.2020.1]
features = +osvvm

; 3. Name + version + edition - Starter Edition reduces the set
[tool.modelsim.2020.1.starter]
features = -uvvm
```

Effective feature sets for a `2020.1` tool:

| Identity | Profile used | Effective features |
| --- | --- | --- |
| 2020.1 without an edition-specific profile | `[tool.modelsim.2020.1]` | baseline + `uvvm` + `osvvm` |
| Starter 2020.1 | `[tool.modelsim.2020.1.starter]` | baseline + `osvvm` |
| Unknown version, no edition-specific profile | `[tool.modelsim]` | baseline + `uvvm` |

Note how the Starter profile removes `uvvm` (inherited from the name-only
profile) but keeps `osvvm` (added by the version profile).

## 8. Operational Metadata

A tool profile may declare metadata in addition to `features`:

```ini
[tool.questa.2025.3]
features = +vhdl-2019,+uvvm
modes = batch,gui,project
probe = vsim -version
version_re = vsim\s+(\d+\.\d+)
```

| Key | Meaning |
| --- | --- |
| `features` | Feature additions/removals relative to the inherited set |
| `modes` | Supported run modes: `batch`, `gui`, `project` |
| `probe` | Command used to detect the executable and version |
| `version_re` | Regex extracting the canonical product version from `probe` output |
| `edition_re` | Regex extracting the edition token from `probe` output |

### 8.1 Probe examples

| Tool | Typical probe |
| --- | --- |
| ModelSim / Questa | `vsim -version` |
| Vivado | `vivado -version` |
| XSim | `xvhdl -version` |
| GHDL | `ghdl --version` |

## 9. Environment-Sensitive Features

Some features depend on more than the simulator binary. `uvvm`, `uvm`, and
`osvvm` require mapped or precompiled libraries. The capabilities file is a
**declared baseline**; the runner must confirm actual availability before
running. The runtime probe mechanism is runner-specific and is not currently
represented by a key in this INI file.

This prevents "capable by version, unavailable in this environment" false
positives. A machine without the UVVM mappings is reported as not providing
`uvvm` even when the simulator version supports it.

## 10. Runner Algorithm

For a selected tool and target:

1. Detect the tool executable, canonical version, and normalized edition
   (using `probe`, `version_re`, and `edition_re` when declared).
2. Apply every matching tool profile in file order, using the rules in
  section 7.2.
3. Compute the effective feature set: `defaults + additions - removals`.
4. Compute the target's final `requires` set (per-target `requires` plus any
   manifest-level default declared in the `.f` manifest).
5. If the target requires a feature the tool lacks, skip under `--tb all`
   and error for an explicit `--tb` selection.
6. For environment-sensitive features, run the runtime availability probe
   before proceeding.

## 11. Validation Rules

The parser must reject:

- unknown keys;
- sections out of the required order (see section 5.1);
- duplicate tool profiles;
- feature tokens in any `features` or `.f` declaration that are not in
  `[features] allowed_features` (probable typo);
- `-feature` when the feature is not present in the inherited set (warning);
- missing `[defaults]` section;
- missing `[features] allowed_features`;
- a `probe` that references an unresolvable command;
- a `version_re` or `edition_re` that is invalid regex or would never match
  the probe output (validate against a captured sample during development);
- edition-qualified profiles whose edition token is not reachable from any
  `edition_re` declared for that tool.

Both files validate at parse time so a typo fails early rather than
producing a confusing skip at run time.

## 12. Relationship to the `.f` Manifest

The `.f` manifest declares target requirements; the capabilities file declares
tool features. The runner compares the two:

```text
[tb:basic]
requires =

[tb:uvvm]
requires = +uvvm

[tb:uvm]
requires = +systemverilog,+uvm
```

Manifest `std=` remains separate: `std=2019` selects the compiler flag, while
`requires = vhdl-2019` is a capability check.

## 13. Troubleshooting

### A testbench is unexpectedly skipped

```text
run axis_fifo vhdl modelsim --tb uvvm
  SKIP - feature 'uvvm' not provided
```

Check:

- Is the tool edition captured? A Starter Edition install must select the
  `starter` profile, not a profile intended for another edition.
- Is `uvvm` declared in the tool's profile and actually mapped in the
  environment?
- Does the probe regex still match the detected version string?

### Version regex does not match

Run the probe manually and compare the output with `version_re`:

```text
> vsim -version
Model Technology ModelSim - INTEL FPGA STARTER EDITION vsim 2020.1 Simulator 2020.02 Feb 28 2020
```

The regex `vsim\s+(\d+\.\d+)` captures `2020.1`, not `2020.02`.

### Two tools share one executable

`modelsim` and `questa` both invoke `vsim`. Keep them as separate tool names
and select the correct one in the launcher. Do not merge their profiles.

## 14. Open Questions

- Where should the runtime availability probe results be cached for a
  session?
