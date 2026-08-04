#!/bin/bash
# ===========================================================================
# simulate_xsim.sh -- Generic XSim (Vivado Simulator) simulation launcher
#
# Called from run.sh or directly. Compiles sources from a .f file list
# using xvhdl/xvlog, elaborates with xelab, and runs with xsim.
#
# Arguments:
#   $1  Scripts directory (absolute path to per-IP scripts/ folder)
#   $2  File list name (without .f extension)
#         Examples: vhdl, uvvm, sv
#   $3  Optional flag:
#         gui   -- Launch XSim GUI (xsim --gui)
#         clean -- Delete the xsim/ working directory
#
# Behaviour:
#   - Derives IP name from the scripts directory parent folder.
#   - Resolves $NAME.f as the source file list.
#   - Creates an xsim/ working directory alongside scripts/ (cleaned each run).
#   - Compiles each source in .f order using xvhdl (VHDL) or xvlog -sv (SV),
#     selecting VHDL standard via the optional suffix (93, 2008, 2019).
#   - UVVM auto-detection: uses detect_uvvm.sh to scan [tb] file contents.
#     XSim cannot simulate UVVM (missing libraries), so it skips gracefully.
#   - Elaborates with xelab, then runs with xsim (batch or --gui).
#
# Examples (via run.sh):
#   run.sh axis_fifo xsim vhdl        # XSim VHDL testbench (batch)
#   run.sh axis_fifo xsim uvvm        # XSim UVVM testbench (batch)
#   run.sh axis_fifo xsim vhdl gui    # XSim VHDL (GUI)
# ===========================================================================

SCRIPTS_DIR="$1"
NAME="$2"
GUI="$3"

if [ "$NAME" = "clean" ]; then
  rm -rf "$SCRIPTS_DIR/../xsim" 2>/dev/null
  echo "[simulate_xsim] Done."
  exit 0
fi

if [ -z "$NAME" ]; then
  echo "Usage: $0 <scripts_dir> <name> [gui|clean]"
  exit 1
fi

IP_NAME="$(basename "$(dirname "$SCRIPTS_DIR")")"
FPGA_IP_ROOT="$(cd "$SCRIPTS_DIR/../.." && pwd)"
FILE_LIST="$SCRIPTS_DIR/${NAME}.f"

# --- Pre-compilation checks ---
# Verify the file list exists before proceeding. A missing .f file is a
# user error (wrong name argument or missing file in scripts/).
if [ ! -f "$FILE_LIST" ]; then
  echo "[simulate_xsim] ERROR: File list not found: $FILE_LIST"
  exit 1
fi

# Determine top entity -- parse from the first VHDL file in the [tb]
# section of the .f file (same approach as simulate.sh / simulate.bat).
# Falls back to <ip_name>_tb if parsing fails.
# UVVM auto-detection via shared utility runs first (XSim skips UVVM).
TOP_TB=""
source "$SCRIPTS_DIR/../../common/scripts/detect_uvvm.sh" "$FILE_LIST"
if [ "$IS_UVVM" = "1" ]; then
  echo "[simulate_xsim] SKIPPING: UVVM testbenches require ModelSim/Questa (UVVM libraries not available in XSim)."
  exit 0
fi

# Parse [tb] section: grab the first non-comment, non-section-header line
TB_SECTION=0
while IFS= read -r line; do
  if [ "$line" = "# [tb]" ]; then
    TB_SECTION=1
    continue
  fi
  if [ $TB_SECTION -eq 1 ] && [ -n "$line" ] && [ "${line:0:1}" != "#" ] && [ "${line:0:1}" != "[" ]; then
    TB_REL=$(echo "$line" | awk '{print $1}')
    break
  fi
done < "$FILE_LIST"

if [ -n "$TB_REL" ]; then
  TB_ABS="$FPGA_IP_ROOT/$TB_REL"
  if [ -f "$TB_ABS" ]; then
    TOP_TB=$(grep -i -m1 '^entity ' "$TB_ABS" | awk '{print $2}' | tr -d ';')
  fi
fi
if [ -z "$TOP_TB" ]; then
  TOP_TB="${IP_NAME}_tb"
fi
echo "[simulate_xsim] Top testbench entity: $TOP_TB"

# --- Create clean working directory ---
# The xsim/ directory stores compiled libraries (xvhdl.pb, xvlog.pb),
# elaboration artifacts (xelab.pb), and simulation snapshots (xsim.dir/).
# Remove and recreate it so every run starts fresh.
SIM_DIR="$SCRIPTS_DIR/../xsim"
rm -rf "$SIM_DIR" 2>/dev/null
mkdir -p "$SIM_DIR"
cd "$SIM_DIR" || exit 1

echo "[simulate_xsim] Compiling from $FILE_LIST..."

# --- Parse .f file and compile each source ---
# File lists are author-controlled, so dependency order matters:
# packages before consumers, top entity after components.
# We ignore blank lines, comments (starting with #), and section
# headers ([rtl], [tb], [top]) since XSim compiles everything
# in a single work library regardless of section grouping.
while IFS= read -r LINE; do
  # Trim leading/trailing whitespace -- the .f files may use
  # inconsistent spacing around file paths.
  LINE="$(echo "$LINE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  
  # Skip blank lines and comments
  [ -z "$LINE" ] && continue
  [ "${LINE:0:1}" = "#" ] && continue
  
  # Skip section headers like [rtl], [tb], [top]
  TRIMMED="$(echo "$LINE" | tr -d ' ')"
  [ "${TRIMMED:0:1}" = "[" ] && continue
  
  # Parse each line as: <relative_path> [vhdl_std]
  # The second token is an optional VHDL standard suffix (93, 2008, 2019).
  # If absent, the source defaults to VHDL-2008.
  SRC_PATH="$(echo "$LINE" | awk '{print $1}')"
  STD_FLAG="$(echo "$LINE" | awk '{print $2}')"
  FULL_PATH="../../$SRC_PATH"
  
  EXT="${SRC_PATH##*.}"
  if [ "$EXT" = "sv" ]; then
    echo "[simulate_xsim] Compiling SystemVerilog: $SRC_PATH"
    xvlog -sv --work work "$FULL_PATH" 2>&1 || exit 1
  elif [ "$EXT" = "vhd" ] || [ "$EXT" = "vhdl" ]; then
    # VHDL standard dispatch: map the optional suffix to the correct
    # xvhdl flag. Missing suffix or unrecognized value defaults to --2008.
    if [ "$STD_FLAG" = "93" ]; then
      echo "[simulate_xsim] Compiling VHDL-93: $SRC_PATH"
      xvhdl --work work "$FULL_PATH" 2>&1 || exit 1
    elif [ "$STD_FLAG" = "2019" ]; then
      echo "[simulate_xsim] Compiling VHDL-2019: $SRC_PATH"
      xvhdl --2019 --work work "$FULL_PATH" 2>&1 || exit 1
    else
      echo "[simulate_xsim] Compiling VHDL-2008: $SRC_PATH"
      xvhdl --2008 --work work "$FULL_PATH" 2>&1 || exit 1
    fi
  else
    echo "[simulate_xsim] WARNING: Unsupported file type: $SRC_PATH"
  fi
done < "$FILE_LIST"

# --- Elaboration ---
# xelab links all compiled units into a simulation snapshot. This is the
# step that resolves entity/architecture bindings. Elaboration failure
# means the design has structural issues (missing components, library
# references, or port mismatches).
echo "[simulate_xsim] Elaborating top entity: $TOP_TB..."
xelab "$TOP_TB" || exit 1

# --- Run simulation ---
# Two modes:
#   GUI:  launch xsim --gui in the background (&) so the terminal remains
#         usable. The GUI includes the waveform viewer for debugging.
#   Batch: xsim --runall runs all transactions and exits.
if [ "$GUI" = "gui" ]; then
  echo "[simulate_xsim] Opening $NAME testbench (GUI)..."
  xsim "work.$TOP_TB" --gui &
else
  echo "[simulate_xsim] Running $NAME testbench (batch)..."
  xsim "work.$TOP_TB" --runall
fi
