@echo off
REM ===========================================================================
REM synthesize.bat -- Generic Vivado synthesis & project launcher (common/Windows)
REM
REM Called from run.bat or directly. Reads a .f file list and runs Vivado in
REM non-project (batch) or project (GUI) mode. Uses section-filtered parsing
REM via files_util.tcl to include only [rtl], [top], and [default] sections.
REM
REM Arguments:
REM   %1  Scripts directory (absolute path to per-IP scripts/ folder)
REM   %2  File list name (without .f extension)
REM         Examples: vhdl, sv, uvvm (simulation-only lists work too)
REM   %3  Optional flag:
REM         gui   -- Create a Vivado project and open the GUI
REM         clean -- Delete the vivado/ working directory and .Xil/ cache
REM
REM Behaviour:
REM   - Derives IP name from the scripts directory parent folder.
REM   - Resolves %NAME%.f as the source file list.
REM   - Creates a vivado/ working directory alongside scripts/ (cleaned each run).
REM   - Skips .f files without a [top] section (simulation-only lists).
REM   - Batch mode: runs synth_vivado.tcl (non-project synthesis).
REM   - GUI mode: runs synth_vivado_project.tcl, then opens the .xpr.
REM   - All Tcl output is logged to vivado.log in the vivado/ directory.
REM
REM Examples (via run.bat):
REM   run axis_fifo vivado vhdl        # Non-project VHDL synthesis (batch)
REM   run axis_fifo vivado sv gui      # SV project + Vivado GUI
REM ===========================================================================
setlocal enabledelayedexpansion

set "SCRIPTS_DIR=%~1"
set "NAME=%~2"
set "GUI=%~3"

if /I "%NAME%"=="clean" goto :clean
if "%NAME%"=="" (
  echo [synthesize] ERROR: Missing arguments.
  exit /b 1
)

REM Derive IP name from scripts directory parent
for %%I in ("%SCRIPTS_DIR%\..") do set "IP_NAME=%%~nxI"

set "FILE_LIST=%SCRIPTS_DIR%\%NAME%.f"
if not exist "%FILE_LIST%" echo [synthesize] ERROR: File list not found: %FILE_LIST% & exit /b 1

REM --- Check for synthesis-required [top] section ---
REM Only .f files with a [top] section can be synthesized. Simulation-only
REM file lists (like uvvm.f) define testbench sources but no top-level
REM wrapper. Running Vivado on those would fail with missing-entity errors.
REM The shared check_top_section.bat utility does content-aware detection:
REM it verifies the [top] header exists AND has at least one file entry.
call "%~dp0check_top_section.bat" "%FILE_LIST%"
if "%HAS_TOP%"=="0" (
  echo [synthesize] SKIPPING: %NAME%.f has no [top] section ^(synthesis requires a top-level design^).
  exit /b 0
)

REM Convert backslashes for Tcl
set "FILE_LIST=%FILE_LIST:\=/%"

set "COMMON_DIR=%~dp0"
set "COMMON_DIR=%COMMON_DIR:~0,-1%"

REM --- Parse top synthesis entity from [top] section of .f file ---
REM Scans for `# [top]`, reads the file on the next non-comment line,
REM extracts the entity name. Falls back to <ip_name>_top.
set "TOP_ENTITY="
set "TOP_REL="
set "TOP_SECTION=0"
set "FILE_LIST_WIN=%SCRIPTS_DIR%\%NAME%.f"
for /F "tokens=*" %%L in (%FILE_LIST_WIN%) do (
  set "LINE=%%L"
  if "!LINE!"=="# [top]" set "TOP_SECTION=1"
  if !TOP_SECTION! EQU 1 (
    if not "!LINE!"=="" if not "!LINE:~0,1!"=="#" if not "!LINE!"=="# [top]" (
      set "TOP_REL=!LINE!"
      goto :got_top
    )
  )
)
:got_top
if defined TOP_REL (
  REM Strip optional VHDL standard suffix (" 93", " 2008", " 2019")
  for /F "tokens=1" %%P in ("!TOP_REL!") do set "TOP_REL=%%P"
  REM Convert forward slashes to backslashes for findstr
  set "TOP_REL=!TOP_REL:/=\!"
  set "TOP_ABS=%SCRIPTS_DIR%\..\..\!TOP_REL!"
  for /F "tokens=2" %%E in ('findstr /I /B "entity" "!TOP_ABS!" 2^>nul') do (
    set "TOP_ENTITY=%%E"
  )
)
if not defined TOP_ENTITY (
  for %%I in ("%SCRIPTS_DIR%\..") do set "TOP_ENTITY=%%~nxI_top"
)
echo [synthesize] Top entity: !TOP_ENTITY!

REM --- Create clean working directory ---
REM Remove and recreate the vivado/ working directory so each synthesis
REM run starts fresh -- no stale project files, logs, or checkpoints.
set "SYNTH_DIR=%SCRIPTS_DIR%\..\vivado"
if exist "%SYNTH_DIR%" rmdir /s /q "%SYNTH_DIR%" 2>nul
mkdir "%SYNTH_DIR%" 2>nul

pushd "%SYNTH_DIR%"

if /I "%GUI%"=="gui" goto :run_gui

echo [synthesize] Running non-project synthesis (batch)...
call vivado -mode batch -source "%COMMON_DIR%/synth_vivado.tcl" -tclargs !TOP_ENTITY! %FILE_LIST%
popd
exit /b %ERRORLEVEL%

:run_gui
echo [synthesize] Creating Vivado project and opening GUI...
call vivado -mode batch -source "%COMMON_DIR%/synth_vivado_project.tcl" -tclargs %IP_NAME%_top %FILE_LIST%
set "XPR=%IP_NAME%_top_proj\%IP_NAME%_top_proj.xpr"
if exist "%XPR%" (
  start "" vivado "%XPR%"
) else (
  echo [synthesize] ERROR: Vivado project file not found!
  dir *.xpr /s
)
popd
exit /b %ERRORLEVEL%

:clean
echo [synthesize] Removing vivado artifacts...
for %%f in ("%SCRIPTS_DIR%\..\vivado\*.log" "%SCRIPTS_DIR%\..\vivado\*.jou") do if exist "%%f" del /f /q "%%f"
if exist "%SCRIPTS_DIR%\..\vivado\.Xil" rmdir /s /q "%SCRIPTS_DIR%\..\vivado\.Xil" 2>nul
set "SYNTH_DIR=%SCRIPTS_DIR%\..\vivado"
if exist "%SYNTH_DIR%" rmdir /s /q "%SYNTH_DIR%" 2>nul
echo [synthesize] Done.
exit /b 0
