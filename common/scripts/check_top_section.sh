#!/bin/bash
# ===========================================================================
# check_top_section.sh — Check if a .f file has files in its [top] section
#
# Usage:   source check_top_section.sh <file_list.f>
# Sets:    HAS_TOP=1 if [top] section has at least one file, else 0
#
# Example: source check_top_section.sh /proj/axis_fifo/scripts/vhdl.f
# ===========================================================================
HAS_TOP=0
if [ -z "$1" ]; then return; fi

# --- Section-tracking state machine ---
# Walks the .f file looking for a [top] section. An empty [top] header
# with no file entries below it does NOT count — synthesis needs actual
# source files. This is more precise than a simple grep for "[top]".
IN_TOP=0

while IFS= read -r LINE; do
  LINE="$(echo "$LINE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -z "$LINE" ] && continue

  # --- Track section headers ---
  # Lines starting with # are commented. After stripping the # marker
  # and whitespace, a [...] token is a section header. Enter [top]
  # mode on match; leave on any other section header.
  if [ "${LINE:0:1}" = "#" ]; then
    STRIPPED="$(echo "$LINE" | sed 's/#//' | tr -d ' ')"
    if [ "$STRIPPED" = "[top]" ]; then
      IN_TOP=1
    elif echo "$STRIPPED" | grep -q '^\['; then
      IN_TOP=0
    fi
    continue
  fi

  # --- Active file entry in [top] section ---
  # Any non-blank, non-header line inside the [top] section means
  # there is actual synthesis content. Set HAS_TOP=1 and exit.
  if [ "$IN_TOP" = "1" ]; then
    HAS_TOP=1
    return
  fi
done < "$1"
