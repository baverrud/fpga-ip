#!/bin/bash
# ===========================================================================
# synthesize.sh -- Generic Vivado synthesis & project launcher (common/Linux)
#
# Called from run.sh or directly. Reads a .f file list and runs Vivado in
# non-project (batch) or project (GUI) mode. Uses section-filtered parsing
# via files_util.tcl to include only [rtl], [top], and [default] sections.
#
# Arguments:
#   $1  Scripts directory (absolute path to per-IP scripts/ folder)
#   $2  File list name (without .f extension)
#         Examples: vhdl, sv, uvvm
#   $3  Optional flag:
#         gui   -- Create a Vivado project and open the GUI
#         clean -- Delete the vivado/ working directory and .Xil/ cache
#
# Behaviour:
#   - Derives IP name from the scripts directory parent folder.
#   - Resolves $NAME.f as the source file list.
#   - Creates a vivado/ working directory alongside scripts/ (cleaned each run).
#   - Skips .f files without a [top] section (simulation-only lists).
#   - Batch mode: runs synth_vivado.tcl (non-project synthesis).
#   - GUI mode: runs synth_vivado_project.tcl, then opens the .xpr.
#   - All Tcl output is logged to vivado.log in the vivado/ directory.
#
# Examples (via run.sh):
#   run.sh axis_fifo vivado vhdl        # Non-project VHDL synthesis (batch)
#   run.sh axis_fifo vivado sv gui      # SV project + Vivado GUI
# ===========================================================================

SCRIPTS_DIR="$1"
NAME="$2"
GUI="$3"

if [ "$NAME" = "clean" ]; then
  rm -rf "$SCRIPTS_DIR/../vivado" 2>/dev/null
  echo "[synthesize] Done."
  exit 0
fi

if [ -z "$NAME" ]; then
  echo "Usage: $0 <scripts_dir> <name> [gui|clean]"
  exit 1
fi

IP_NAME="$(basename "$(dirname "$SCRIPTS_DIR")")"
FILE_LIST="$SCRIPTS_DIR/${NAME}.f"

if [ ! -f "$FILE_LIST" ]; then
  echo "[synthesize] ERROR: File list not found: $FILE_LIST"
  exit 1
fi

# Skip synthesis if the .f file has no [top] section (simulation-only lists).
# Uses the shared check_top_section.sh utility for parity with synthesize.bat
# (verifies the [top] section has at least one file, not just a header line).
source "$(dirname "$0")/check_top_section.sh" "$FILE_LIST"
if [ "$HAS_TOP" != "1" ]; then
  echo "[synthesize] SKIPPING: ${NAME}.f has no [top] section (synthesis requires a top-level design)."
  exit 0
fi

COMMON_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Create clean working directory ---
# Remove and recreate the vivado/ working directory so each synthesis
# run starts fresh -- no stale project files, logs, or checkpoints.
rm -rf "$SCRIPTS_DIR/../vivado" 2>/dev/null
mkdir -p "$SCRIPTS_DIR/../vivado"
cd "$SCRIPTS_DIR/../vivado"

if [ "$GUI" = "gui" ]; then
  # --- Project mode (GUI) ---
  # Creates a .xpr project with Design Sources ([rtl] + [top]) and
  # Simulation Sources ([tb]) in separate filesets. Then launches the
  # Vivado GUI for interactive analysis. The background (&) keeps the
  # terminal usable; note that Vivado is a heavy application that may
  # take several seconds to start.
  echo "[synthesize] Creating Vivado project and opening GUI..."
  vivado -mode batch -source "$COMMON_DIR/synth_vivado_project.tcl" -tclargs "${IP_NAME}_top" "$FILE_LIST"
  XPR="${IP_NAME}_top_proj/${IP_NAME}_top_proj.xpr"
  if [ -f "$XPR" ]; then
    vivado "$XPR" &
  else
    echo "[synthesize] ERROR: Vivado project file not found!"
  fi
else
  # --- Non-project mode (batch) ---
  # Headless synthesis via synth_vivado.tcl. No .xpr project is created.
  # Produces utilization.rpt and timing.rpt in the vivado/ directory.
  # This is the CI-friendly, minimal-overhead synthesis flow.
  echo "[synthesize] Running non-project synthesis (batch)..."
  vivado -mode batch -source "$COMMON_DIR/synth_vivado.tcl" -tclargs "${IP_NAME}_top" "$FILE_LIST"
fi
