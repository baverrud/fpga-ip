@echo off
REM ===========================================================================
REM simulate.bat — Generic ModelSim/Questa simulation launcher (common/Windows)
REM
REM Called from run.bat or directly. Compiles sources from a .f file list,
REM then runs the simulation. Supports auto-detection of UVVM testbenches.
REM
REM Arguments:
REM   %1  Scripts directory (absolute path to per-IP scripts/ folder)
REM   %2  File list name (without .f extension)
REM         Examples: vhdl, uvvm, sv
REM   %3  Optional flag:
REM         gui     — Launch ModelSim GUI with waveform viewer
REM         clean   — Delete the modelsim/ working directory
REM         project — Launch GUI + create ModelSim project file (.mpf)
REM   %4  Additional modifier (only when %3=gui):
REM         project — Also create ModelSim project file (.mpf)
REM
REM Behaviour:
REM   - Derives IP name from the scripts directory parent folder.
REM   - Resolves %NAME%.f as the source file list.
REM   - Creates a modelsim/ working directory alongside scripts/.
REM   - Auto-detects top testbench entity from [tb] section of .f file.
REM     Falls back to <ip_name>_tb if not found.
REM   - Invokes sim_modelsim.do with the resolved top entity.
REM   - UVVM auto-detection: content-based — scans [tb] files listed in
REM     the .f for "uvvm_vvc_framework" (handles any .f filename).
REM   - In GUI mode, wave.do is auto-loaded if present.
REM
REM Examples (via run.bat):
REM   run axis_fifo modelsim vhdl       # VHDL simple testbench (batch)
REM   run axis_fifo modelsim uvvm       # UVVM testbench (batch)
REM   run axis_fifo modelsim vhdl gui   # VHDL (GUI + waveforms)
REM ===========================================================================
setlocal enabledelayedexpansion

set "SCRIPTS_DIR=%~1"
set "NAME=%~2"
set "GUI=%~3"
set "PROJECT=%~4"

REM If %3 is "project", treat as GUI mode + project flag
if /I "%GUI%"=="project" (
  set "PROJECT=project"
  set "GUI=gui"
)

if /I "%NAME%"=="clean" goto :clean
if "%NAME%"=="" (
  echo [simulate] ERROR: Missing arguments.
  exit /b 1
)

REM Derive IP name from scripts directory parent
for %%I in ("%SCRIPTS_DIR%\..") do set "IP_NAME=%%~nxI"

REM Save Windows path for local file operations (findstr chokes on /)
set "FILE_LIST_WIN=%SCRIPTS_DIR%\%NAME%.f"
set "FILE_LIST=%FILE_LIST_WIN:\=/%"

REM --- Parse top testbench entity from [tb] section of .f file ---
REM Reads the first non-comment line after `# [tb]`, extracts the entity
REM name from that VHDL file. Falls back to <ip_name>_tb if not found.
set "TB_REL="
for /F "tokens=*" %%L in (%FILE_LIST_WIN%) do (
  set "LINE=%%L"
  if "!LINE!"=="# [tb]" set "TB_SECTION=1"
  if defined TB_SECTION (
    if not "!LINE!"=="" if not "!LINE:~0,1!"=="#" if not "!LINE!"=="# [tb]" (
      set "TB_REL=!LINE!"
    )
  )
)
:got_tb
if defined TB_REL (
  REM Strip optional VHDL standard suffix (" 93", " 2008", " 2019")
  for /F "tokens=1" %%P in ("!TB_REL!") do set "TB_REL=%%P"
  REM Convert forward slashes to backslashes for findstr
  set "TB_REL=!TB_REL:/=\!"
  set "TB_ABS=%SCRIPTS_DIR%\..\..\!TB_REL!"
  for /F "tokens=2" %%E in ('findstr /I /B "entity" "!TB_ABS!" 2^>nul') do (
    set "TOP_TB=%%E"
  )
)
if not defined TOP_TB (
  for %%I in ("%SCRIPTS_DIR%\..") do set "TOP_TB=%%~nxI_tb"
)
echo [simulate] Top testbench entity: !TOP_TB!

REM --- Configure UVVM time resolution ---
REM The TIMING variable is currently empty (UVVM auto-detection is handled
REM inside sim_modelsim.do, which scans file contents for the UVVM library
REM reference). If UVVM is detected there, the .do script sets -t fs itself.
REM This slot exists for future explicit -t override from the launcher.
set "TIMING="

REM --- Create clean working directory ---
REM The modelsim/ directory holds compiled libraries, transcripts, and
REM artifacts. We remove and recreate it so every run starts
REM fresh — no stale object files from previous compiles.
REM Project mode uses a separate modelsim_proj/ directory so it can
REM coexist with non-project simulation runs. Since *_proj/ is ignored
REM in git/VS Code, naming it modelsim_proj/ prevents IDE file-scanning
REM locks that cause "Access is denied" when compiling/saving in the GUI.
set "SIM_DIR=%SCRIPTS_DIR%\..\modelsim"
if /I "%PROJECT%"=="project" (
  set "SIM_DIR=%SCRIPTS_DIR%\..\modelsim_proj"
)
if exist "%SIM_DIR%" rmdir /s /q "%SIM_DIR%" 2>nul
mkdir "%SIM_DIR%" 2>nul

REM --- Handle local modelsim.ini for writeable project mode ---
REM When MODELSIM environment variable points to the read-only global UVVM
REM modelsim.ini, ModelSim GUI operations (like compile, project save, or exit)
REM will fail with "Access is denied" / "Unable to replace existing ini file"
REM on the .mpf because ModelSim attempts to modify the global directory.
REM Copying modelsim.ini locally and unsetting the env var completely fixes this.
if /I "%PROJECT%"=="project" (
  if defined MODELSIM (
    if exist "%MODELSIM%" (
      copy /Y "%MODELSIM%" "%SIM_DIR%\modelsim.ini" >nul
      attrib -R "%SIM_DIR%\modelsim.ini" >nul
    )
  )
  set "MODELSIM="
)

REM --- Resolve path to the shared simulation engine ---
REM sim_modelsim.do is the universal ModelSim/Questa Tcl engine that
REM handles compiling, elaborating, and running all IP blocks. We resolve
REM its path relative to the modelsim/ working directory before pushing.
set "SIM_DO=%SCRIPTS_DIR%\..\..\common\scripts\sim_modelsim.do"
REM Normalize backslashes to forward slashes for Tcl compatibility
set "SIM_DO=%SIM_DO:\=/%"

REM --- Enter the working directory ---
REM pushd saves the current directory so we can popd back after the sim
REM completes. The .do engine resolves file paths relative to where vsim
REM was launched from, so we must run from inside modelsim/.
pushd "%SIM_DIR%"

if /I "%GUI%"=="gui" goto :run_gui

REM --- Batch mode ---
REM vsim -c runs the simulator without a GUI. The -do flag passes our
REM Tcl engine script with the top entity, file list, and optional time
REM resolution. The engine handles all compilation + elaboration + run.
echo [simulate] Running %NAME% testbench (batch)...
if "%TIMING%"=="" (
  vsim -c -do "do %SIM_DO% work.%TOP_TB% %FILE_LIST% %PROJECT%"
) else (
  vsim -c -do "do %SIM_DO% work.%TOP_TB% %FILE_LIST% %TIMING% %PROJECT%"
)
popd
exit /b %ERRORLEVEL%

:run_gui
echo [simulate] Opening %NAME% testbench (GUI)...
if "%TIMING%"=="" (
  start /B "ModelSim" vsim -do "do %SIM_DO% work.%TOP_TB% %FILE_LIST% %PROJECT%"
) else (
  start /B "ModelSim" vsim -do "do %SIM_DO% work.%TOP_TB% %FILE_LIST% %TIMING% %PROJECT%"
)
popd
exit /b %ERRORLEVEL%

:clean
echo [simulate] Removing modelsim artifacts...
set "SIM_DIR=%SCRIPTS_DIR%\..\modelsim"
if exist "%SIM_DIR%" rmdir /s /q "%SIM_DIR%" 2>nul
echo [simulate] Done.
exit /b 0
