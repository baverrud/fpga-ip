#!/bin/bash
# ===========================================================================
# detect_uvvm.sh - UVVM detection utility (shared/Linux)
#
# Scans the content of [tb] files listed in a .f file for references to
# "uvvm_vvc_framework" or "library uvvm_util". All UVVM VVC-based
# testbenches reference uvvm_vvc_framework via:
#   library uvvm_vvc_framework;
# UVVM-util-only testbenches reference:
#   library uvvm_util;
#
# Usage:   source detect_uvvm.sh <file_list.f>
# Sets:    IS_UVVM=1 if UVVM detected, else IS_UVVM=0
#
# Example: source detect_uvvm.sh /proj/axis_fifo/scripts/vhdl.f
# ===========================================================================
IS_UVVM=0
if [ -z "$1" ]; then return; fi

# Resolve sub/fpga-ip root directory from the .f file path.
# The .f is at <ip>/scripts/<name>.f, so going up two levels
# reaches sub/fpga-ip/ where all IP roots are.
F_DIR="$(cd "$(dirname "$1")/../.." && pwd)"

# --- Section-tracking state machine ---
# We walk the .f file looking for a [tb] section, then check each file
# listed there for the UVVM library reference.
IN_TB=0

while IFS= read -r LINE; do
  # Trim leading/trailing whitespace
  LINE="$(echo "$LINE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -z "$LINE" ] && continue

  # --- Track section headers ---
  # Lines starting with # are either comments or section markers.
  # If they contain [tb] we start collecting file paths.
  # Any other [...] section header stops collection.
  if [ "${LINE:0:1}" = "#" ]; then
    STRIPPED="$(echo "$LINE" | sed 's/#//' | tr -d ' ')"
    if [ "$STRIPPED" = "[tb]" ]; then
      IN_TB=1
    elif echo "$STRIPPED" | grep -q '^\['; then
      IN_TB=0
    fi
    continue
  fi

  # --- Process file paths in [tb] section ---
  # Extract the first whitespace-delimited token as the file path.
  # If that file contains "uvvm_vvc_framework" or a "library uvvm_util"
  # declaration (case-insensitive), we set IS_UVVM=1 and return
  # immediately -- no need to scan further.
  if [ "$IN_TB" = "1" ]; then
    TB_FILE="$(echo "$LINE" | awk '{print $1}')"
    if [ -f "$F_DIR/$TB_FILE" ] && grep -iqE "uvvm_vvc_framework|library[[:space:]]+uvvm_util" "$F_DIR/$TB_FILE" 2>/dev/null; then
      IS_UVVM=1
      return
    fi
  fi
done < "$1"
