@echo off
REM ===========================================================================
REM detect_uvvm.bat - UVVM detection utility (shared)
REM
REM Scans the content of [tb] files listed in a .f file for references to
REM "uvvm_vvc_framework" or "library uvvm_util". All UVVM VVC-based
REM testbenches reference uvvm_vvc_framework via:
REM   library uvvm_vvc_framework;
REM UVVM-util-only testbenches reference:
REM   library uvvm_util;
REM
REM Usage:   call detect_uvvm.bat <file_list.f>
REM Sets:    IS_UVVM=1 if UVVM detected, else IS_UVVM=0
REM
REM Example: call detect_uvvm.bat C:\proj\axis_fifo\scripts\vhdl.f
REM ===========================================================================
setlocal enabledelayedexpansion
set "IS_UVVM=0"
if "%1"=="" endlocal & exit /b 0

REM --- Resolve sub/fpga-ip root directory from .f file path ---
REM The .f file sits in <ip>/scripts/, so going up two levels reaches
REM sub/fpga-ip/ where all IP roots live.
for %%I in ("%~dp1..\..") do set "F_DIR=%%~fI"

REM --- Section-tracking state machine ---
REM We parse the .f file line-by-line looking for a [tb] section header.
REM IN_TB tracks whether we are inside [tb]. Lines there contain file
REM paths we scan for the UVVM library reference string.
set "IN_TB=0"

for /F "usebackq tokens=* delims=" %%L in ("%~1") do (
  set "LINE=%%L"
  set "FIRST=!LINE:~0,1!"
  if "!FIRST!"=="#" (
    REM --- Section header detected ---
    REM Strip the # and whitespace to extract the section name.
    REM If [tb], start collecting. Any other [...] section stops.
    set "STR=!LINE:#=!"
    for /F "tokens=*" %%S in ("!STR!") do (
      set "TMP=%%S"
      set "TMP=!TMP: =!"
      if "!TMP!"=="[tb]" (set "IN_TB=1") else if "!TMP:~0,1!"=="[" (set "IN_TB=0")
    )
  ) else if "!IN_TB!"=="1" if not "!LINE!"=="" (
    REM --- File path in [tb] section ---
    REM Extract the first token (file path), then grep for UVVM.
    REM FINDSTR BUG: findstr CHOKES on forward slashes in file paths
    REM (drops directory components silently). We normalize / to \
    REM before the call to guarantee correct path resolution.
    REM
    REM We search for either "uvvm_vvc_framework" (VVC-based UVVM TBs)
    REM or "library uvvm_util" (util-only UVVM TBs). Either match
    REM triggers IS_UVVM=1.
    for /F "tokens=1 delims= " %%A in ("!LINE!") do (
      set "TB_FILE=%%A"
      REM Normalize forward slashes to backslashes for findstr
      set "TB_FILE=!TB_FILE:/=\!"
      if exist "%F_DIR%\!TB_FILE!" (
        findstr /i /r "uvvm_vvc_framework library[ ][ ]*uvvm_util" "%F_DIR%\!TB_FILE!" >nul 2>&1
        if not errorlevel 1 (
          endlocal & set "IS_UVVM=1"
          exit /b 0
        )
      )
    )
  )
)
endlocal & set "IS_UVVM=%IS_UVVM%"
exit /b 0
