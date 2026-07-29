#!/bin/bash
# ===========================================================================
# simulate.sh — Generic ModelSim/Questa simulation launcher (common/Linux)
#
# Called from run.sh or directly. Compiles sources from a .f file list,
# then runs the simulation. Supports auto-detection of UVVM testbenches.
#
# Arguments:
#   $1  Scripts directory (absolute path to per-IP scripts/ folder)
#   $2  File list name (without .f extension)
#         Examples: vhdl, uvvm, sv
#   $3  Optional flag:
#         gui   — Launch ModelSim GUI with waveform viewer
#         clean — Delete the modelsim/ working directory
#
# Behaviour:
#   - Derives IP name from the scripts directory parent folder.
#   - Resolves $NAME.f as the source file list.
#   - Creates a modelsim/ working directory alongside scripts/.
#   - Invokes sim_modelsim.do with top entity work.<ip>_tb.
#   - UVVM auto-detection: content-based — scans [tb] files listed in
#     the .f for "uvvm_vvc_framework" (handles any .f filename).
#   - In GUI mode, wave.do is auto-loaded if present.
#
# Examples (via run.sh):
#   run.sh axis_fifo modelsim vhdl       # VHDL simple testbench (batch)
#   run.sh axis_fifo modelsim uvvm       # UVVM testbench (batch)
#   run.sh axis_fifo modelsim vhdl gui   # VHDL (GUI + waveforms)
# ===========================================================================

SCRIPTS_DIR="$1"
NAME="$2"
GUI="$3"

if [ "$NAME" = "clean" ]; then
  rm -rf "$SCRIPTS_DIR/../modelsim" 2>/dev/null
  echo "[simulate] Done."
  exit 0
fi

if [ -z "$NAME" ]; then
  echo "Usage: $0 <scripts_dir> <name> [gui|clean]"
  exit 1
fi

IP_NAME="$(basename "$(dirname "$SCRIPTS_DIR")")"
FILE_LIST="$SCRIPTS_DIR/${NAME}.f"
TOP_TB="${IP_NAME}_tb"

# --- UVVM time resolution ---
# TIMING is empty by default; UVVM auto-detection happens inside
# sim_modelsim.do (content-based scan of [tb] files). If detected,
# the .do engine sets -t fs itself. Reserved for future explicit
# time-resolution overrides from the launcher.
TIMING=""

# Resolve absolute path to the shared simulation engine.
# sim_modelsim.do handles compile, elaborate, and run for all IP blocks.
SIM_DO="$(cd "$SCRIPTS_DIR/../../common/scripts" && pwd)/sim_modelsim.do"

# --- Prepare clean working directory ---
# The modelsim/ directory stores compiled libraries and simulation
# artifacts. Remove and recreate it so every run starts fresh.
rm -rf "$SCRIPTS_DIR/../modelsim" 2>/dev/null
mkdir -p "$SCRIPTS_DIR/../modelsim"

# --- Enter working directory ---
# The .do engine resolves file paths relative to vsim's launch
# directory, so we must cd into modelsim/ before invoking vsim.
cd "$SCRIPTS_DIR/../modelsim"

if [ "$GUI" = "gui" ]; then
  # --- GUI mode ---
  # vsim without -c opens the waveform viewer. The engine auto-loads
  # wave.do from scripts/ or tb/ if present. Background (&) detaches
  # the GUI so the terminal stays interactive.
  echo "[simulate] Opening $NAME testbench (GUI)..."
  if [ -z "$TIMING" ]; then
    vsim -do "do $SIM_DO work.$TOP_TB $FILE_LIST" &
  else
    vsim -do "do $SIM_DO work.$TOP_TB $FILE_LIST $TIMING" &
  fi
else
  # --- Batch mode ---
  # vsim -c runs headless. The -do script compiles all sources,
  # elaborates the design, runs the simulation, and exits.
  echo "[simulate] Running $NAME testbench (batch)..."
  if [ -z "$TIMING" ]; then
    vsim -c -do "do $SIM_DO work.$TOP_TB $FILE_LIST"
  else
    vsim -c -do "do $SIM_DO work.$TOP_TB $FILE_LIST $TIMING"
  fi
fi
