#!/bin/bash
# ===========================================================================
# run.sh -- Repository root FPGA IP tool launcher (Linux)
#
# Usage:
#   run.sh <ip> <tool> <name> [gui]   Run tool on IP configuration
#   run.sh <ip> clean                 Remove all artifacts
#   run.sh <ip> all                   Run all batch (non-GUI) permutations
#
# Arguments:
#   <ip>     IP block directory name (e.g., axis_fifo)
#   <tool>   EDA tool: modelsim | vivado | xsim | all
#   <name>   File list name (without .f). Examples: vhdl, uvvm, sv
#   [gui]    Optional -- launch GUI with waveforms
#   clean    Replaces <tool> <name> -- removes modelsim/, vivado/, xsim/
#
# Examples:
#   run.sh axis_fifo modelsim vhdl        # ModelSim VHDL (batch)
#   run.sh axis_fifo modelsim uvvm        # ModelSim UVVM (batch)
#   run.sh axis_fifo modelsim sv gui      # ModelSim SV (GUI)
#   run.sh axis_fifo vivado vhdl          # Vivado synthesis (batch)
#   run.sh axis_fifo all                  # All batch permutations
#   run.sh axis_fifo clean                # Remove all artifacts
#
# File-List Convention:
#   Each <name> maps to axis_fifo/scripts/<name>.f, which lists the
#   source files to compile/synthesize. Section headers ([rtl], [tb],
#   [top]) let the same .f serve both simulation and synthesis flows.
# ===========================================================================

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

IP="$1"
TOOL="$2"
NAME="$3"
GUI="$4"

if [ -z "$IP" ] || [ -z "$TOOL" ]; then
  echo "Usage: $0 <ip> <tool> <name> [gui|clean|all]"
  echo "Tools: modelsim vivado xsim"
  exit 1
fi

SCRIPT_DIR="$REPO_DIR/$IP/scripts"
if [ ! -d "$SCRIPT_DIR" ]; then
  echo "[run] ERROR: IP '$IP' not found at $SCRIPT_DIR"
  exit 1
fi

if [ "$TOOL" = "clean" ]; then
  "$REPO_DIR/common/scripts/simulate.sh" "$SCRIPT_DIR" clean
  "$REPO_DIR/common/scripts/synthesize.sh" "$SCRIPT_DIR" clean
  "$REPO_DIR/common/scripts/simulate_xsim.sh" "$SCRIPT_DIR" clean
  echo "[run] Done."
  exit 0
fi

if [ "$TOOL" = "all" ]; then
  FAILED=0
  PASSED=0
  SKIPPED=0
  echo "======================================================================="
  echo " Running all batch permutations for IP: $IP"
  echo "======================================================================="

  # Scan available tools
  TOOLS=""
  for t in xsim modelsim vivado; do
    bin=""
    case "$t" in
      modelsim) bin="vsim" ;;
      vivado)   bin="vivado" ;;
      xsim)     bin="xvhdl" ;;
    esac
    if command -v "$bin" >/dev/null 2>&1; then
      echo "   $t: found"
      TOOLS="$TOOLS $t"
    else
      echo "   $t: NOT FOUND"
    fi
  done
  echo ""

  # --- Pre-compute metadata for every .f file ---
  # We scan all file lists ONCE and cache the results in three parallel arrays:
  #   FILE_NAMES[]   -- basename of each .f file (e.g. "vhdl", "uvvm", "sv")
  #   UVVM_FLAGS[]   -- 1 if [tb] files reference "uvvm_vvc_framework", else 0
  #   HAS_TOP_FLAGS[] -- 1 if [top] section has at least one file entry, else 0
  #
  # Caching avoids re-running detect_uvvm.sh and check_top_section.sh for
  # every tool permutation of the same file list. For N files x M tools,
  # this reduces detection calls from NxM to N.
  FILE_LISTS=("$SCRIPT_DIR"/*.f)
  if [ ! -e "${FILE_LISTS[0]}" ]; then
    echo "[run] ERROR: No .f file lists found under $SCRIPT_DIR"
    exit 1
  fi

  FILE_NAMES=()
  UVVM_FLAGS=()
  HAS_TOP_FLAGS=()
  for f in "${FILE_LISTS[@]}"; do
    name="$(basename "$f" .f)"
    FILE_NAMES+=("$name")

    source "$REPO_DIR/common/scripts/detect_uvvm.sh" "$f"
    UVVM_FLAGS+=("$IS_UVVM")

    source "$REPO_DIR/common/scripts/check_top_section.sh" "$f"
    HAS_TOP_FLAGS+=("$HAS_TOP")
  done

  # --- Run a single tool/file-list permutation ---
  # Uses pre-computed metadata from the arrays above (UVVM_FLAGS,
  # HAS_TOP_FLAGS) indexed by the file list position. The index
  # indirection lets us look up the cached flags without reparsing.
  run_one() {
    local tool="$1"
    local idx="$2"
    local name="${FILE_NAMES[$idx]}"
    local is_uvvm="${UVVM_FLAGS[$idx]}"
    local has_top="${HAS_TOP_FLAGS[$idx]}"

    # xsim skips UVVM testbenches because UVVM libraries are not
    # distributed with the default XSim toolchain.
    if [ "$tool" = "xsim" ] && [ "$is_uvvm" = "1" ]; then
        echo "   [SKIP] xsim $name (UVVM not supported)"
        SKIPPED=$((SKIPPED + 1))
        return
    fi

    # vivado skips .f files without a [top] section. Simulation-only
    # file lists (e.g. uvvm.f) have no top wrapper and would cause
    # syntax errors if fed to synth_design.
    if [ "$tool" = "vivado" ] && [ "$has_top" != "1" ]; then
        echo "   [SKIP] vivado $name (no [top] section)"
        SKIPPED=$((SKIPPED + 1))
        return
    fi

    echo "   [RUN]  $tool $name"
    case "$tool" in
      modelsim) "$REPO_DIR/common/scripts/simulate.sh" "$SCRIPT_DIR" "$name" >/dev/null 2>&1 ;;
      vivado)   "$REPO_DIR/common/scripts/synthesize.sh" "$SCRIPT_DIR" "$name" >/dev/null 2>&1 ;;
      xsim)     "$REPO_DIR/common/scripts/simulate_xsim.sh" "$SCRIPT_DIR" "$name" >/dev/null 2>&1 ;;
    esac
    if [ $? -eq 0 ]; then
      echo "   [PASS] $tool $name"
      PASSED=$((PASSED + 1))
    else
      echo "   [FAIL] $tool $name"
      FAILED=$((FAILED + 1))
    fi
  }

  for tool in $TOOLS; do
    for idx in "${!FILE_NAMES[@]}"; do
      run_one "$tool" "$idx"
    done
  done

  echo ""
  echo "======================================================================="
  echo " SUMMARY"
  echo "======================================================================="
  echo "   TOTAL: $PASSED passed, $FAILED failed, $SKIPPED skipped"
  echo "======================================================================="
  exit $FAILED
fi

if [ -z "$NAME" ]; then
  echo "Usage: $0 <ip> <tool> <name> [gui|clean|all]"
  echo "Tools: modelsim vivado xsim"
  exit 1
fi

cd "$SCRIPT_DIR"

case "$TOOL" in
  modelsim)
    "$REPO_DIR/common/scripts/simulate.sh" "$SCRIPT_DIR" "$NAME" "$GUI"
    ;;
  vivado)
    "$REPO_DIR/common/scripts/synthesize.sh" "$SCRIPT_DIR" "$NAME" "$GUI"
    ;;
  xsim)
    "$REPO_DIR/common/scripts/simulate_xsim.sh" "$SCRIPT_DIR" "$NAME" "$GUI"
    ;;
  *)
    echo "[run] Unknown tool: $TOOL"
    echo "Tools: modelsim vivado xsim"
    exit 1
    ;;
esac
