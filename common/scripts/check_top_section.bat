@echo off
REM ===========================================================================
REM check_top_section.bat — Check if a .f file has files in its [top] section
REM
REM Usage:   call check_top_section.bat <file_list.f>
REM Sets:    HAS_TOP=1 if [top] section has at least one file, else 0
REM
REM Example: call check_top_section.bat C:\proj\axis_fifo\scripts\vhdl.f
REM ===========================================================================
setlocal enabledelayedexpansion
set "HAS_TOP=0"

REM --- Section-tracking state machine ---
REM Walks the .f file looking for a [top] section. If we find one and
REM it contains at least one non-blank, non-comment line (i.e. a file
REM path), then HAS_TOP=1. An empty [top] header with no files below
REM it does NOT count — synthesis needs actual source files to build.
REM This is more precise than a simple grep for "[top]".
set "IN_TOP=0"

for /F "usebackq tokens=* delims=" %%L in ("%~1") do (
  set "LINE=%%L"
  set "FIRST=!LINE:~0,1!"
  if "!FIRST!"=="#" (
    REM --- Section header detected ---
    REM Strip # and whitespace to extract the section name.
    REM If it's [top], enter tracking mode. Any other [...] section
    REM exits tracking mode (e.g., [rtl] or [tb] after [top]).
    set "STR=!LINE:#=!"
    for /F "tokens=*" %%S in ("!STR!") do (
      set "TMP=%%S"
      set "TMP=!TMP: =!"
      if /I "!TMP!"=="[top]" (set "IN_TOP=1") else if "!TMP:~0,1!"=="[" (set "IN_TOP=0")
    )
  ) else if "!IN_TOP!"=="1" if not "!LINE!"=="" (
    REM --- Active file entry in [top] section ---
    REM Any non-blank, non-header line inside the [top] section means
    REM there is actual content to synthesize. Set HAS_TOP=1 and exit.
    endlocal & set "HAS_TOP=1"
    exit /b 0
  )
)
endlocal & set "HAS_TOP=%HAS_TOP%"
exit /b 0
