@echo off
REM ===========================================================================
REM run.bat — Repository root FPGA IP tool launcher (Windows)
REM
REM Usage:
REM   run <ip> <name> <tool> [gui]     Run tool on IP configuration
REM   run <ip> clean                   Remove all artifacts
REM   run <ip> all [<tool>]            Run all .f permutations (optionally filter tool)
REM
REM Arguments:
REM   <ip>     IP block directory name (e.g., axis_fifo)
REM   <name>   File list name (without .f extension). Determines which
REM            sources are compiled. Examples:
REM              vhdl    — VHDL simple testbench (vhdl.f)
REM              uvvm    — UVVM verification (uvvm.f)
REM              sv      — SystemVerilog simple testbench (sv.f)
REM              all     — Run all .f files (see 'all [tool]' above)
REM              clean   — Remove modelsim/, vivado/ and xsim/ artifacts
REM   <tool>   EDA tool to run:
REM              modelsim  — ModelSim/Questa simulation (via simulate.bat)
REM              vivado    — Vivado synthesis (via synthesize.bat)
REM              xsim      — Xilinx XSim simulation (via simulate_xsim.bat)
REM   [gui]    Optional flag to launch GUI mode with waveform viewer.
REM            Omit for batch/headless mode. Not valid with 'all'.
REM   [project] Optional flag to create a ModelSim project file (.mpf).
REM            Can be combined with gui: "run <ip> <name> <tool> gui project"
REM
REM Examples:
REM   run axis_fifo vhdl  modelsim              # ModelSim VHDL (batch)
REM   run axis_fifo uvvm  modelsim              # ModelSim UVVM (batch)
REM   run axis_fifo sv    modelsim gui          # ModelSim SV (GUI)
REM   run axis_fifo vhdl  modelsim project      # ModelSim VHDL (GUI + project)
REM   run axis_fifo vhdl  modelsim gui project  # ModelSim VHDL (GUI + project)
REM
REM File-List Convention:
REM   Each <name> maps to axis_fifo/scripts/<name>.f, which lists the
REM   source files to compile/synthesize. Section headers ([rtl], [tb],
REM   [top]) let the same .f serve both simulation and synthesis flows.
REM
REM CMD Batch Gotchas (read before editing):
REM	a) Delayed-expansion !VAR! inside a parenthesized if/else block that
REM	   is itself inside a for-loop body will CORRUPT CMD's block parser.
REM	   The else branch fires even when the if-condition is true. FIX:
REM	   capture values inside if/else, but echo them AFTER the closing
REM	   paren of if/else, not inside it.
REM	b) %VAR% in for /F 'command' strings is expanded at parse-time.
REM	   If the variable is SET inside the same parenthesized block it
REM	   won't be visible. Use a literal or set it before the block.
REM	c) `call :sub` from within a for-loop body is safe, but errorlevel
REM	   set inside the subroutine persists after return — always check
REM	   errorlevel immediately after the command that sets it.
REM	d) PIPE DEADLOCK: for /F with pipes inside redirected batch stderr
REM	   deadlocks. Use temporary files or if-based filtering instead.
REM	e) Labels with `goto :label` work. `call :label` pushes a new scope
REM	   — use `exit /b` to return, not `goto :eof`.
REM ===========================================================================
setlocal enabledelayedexpansion

set "IP=%~1"
set "NAME=%~2"
set "TOOL=%~3"
set "GUI=%~4"
set "PROJECT=%~5"

if "%IP%"=="" goto :usage
if "%NAME%"=="" goto :usage
if /I "%NAME%"=="clean" goto :clean
if /I "%NAME%"=="all"   goto :run_all
if "%TOOL%"=="" goto :run_name_all

REM Navigate to the IP's scripts directory
set "IP_DIR=%~dp0%IP%\scripts"
if not exist "%IP_DIR%" (
  echo [run] ERROR: IP '%IP%' not found at %IP_DIR%
  exit /b 1
)
cd /d "%IP_DIR%"

if /I "%TOOL%"=="modelsim" goto :simulate
if /I "%TOOL%"=="vivado"   goto :synthesize
if /I "%TOOL%"=="xsim"     goto :simulate_xsim

echo [run] Unknown tool: %TOOL%
goto :usage

:simulate
call ..\..\common\scripts\simulate.bat "%CD%" %NAME% %GUI% %PROJECT%
exit /b %ERRORLEVEL%

:synthesize
call ..\..\common\scripts\synthesize.bat "%CD%" %NAME% %GUI%
exit /b %ERRORLEVEL%

:simulate_xsim
call ..\..\common\scripts\simulate_xsim.bat "%CD%" %NAME% %GUI%
exit /b %ERRORLEVEL%

:clean
set "IP_DIR=%~dp0%IP%\scripts"
if not exist "%IP_DIR%" (
  echo [run] ERROR: IP '%IP%' not found at %IP_DIR%
  exit /b 1
)
cd /d "%IP_DIR%"
call ..\..\common\scripts\simulate.bat "%CD%" clean
call ..\..\common\scripts\simulate_xsim.bat "%CD%" clean
call ..\..\common\scripts\synthesize.bat "%CD%" clean
REM Remove the per-IP sim/ build directory (used by sim.do)
if exist "..\sim" rmdir /s /q "..\sim" 2>nul
echo [run] Done.
exit /b 0

REM ===========================================================================
REM Run a single file list with all available tools.
REM
REM Triggered by: run <ip> <name>  (no tool argument)
REM ===========================================================================
:run_name_all
set "IP_DIR=%~dp0%IP%\scripts"
if not exist "%IP_DIR%" (
  echo [run] ERROR: IP '%IP%' not found at %IP_DIR%
  exit /b 1
)

set "FAILED=0"
set "PASSED=0"
set "SKIPPED=0"

echo =======================================================================
echo  Running file list '%NAME%' for IP: %IP%
echo =======================================================================

REM Warn if GUI flag is set — not valid with multi-tool mode
if not "%GUI%"=="" (
  echo   [WARN] GUI flag ignored: multi-tool mode runs batch only
)
set "GUI="

REM Scan available tools on PATH
REM
REM NOTE: !VER! echo must be AFTER the if/else closing paren, not inside
REM the else block. CMD's delayed expansion corrupts block parsing when
REM !VAR! appears inside a parenthesized if/else within a for-loop body
REM (see CMD Batch Gotchas at top of file).
set "FOUND_XSIM=0"
set "FOUND_MODELSIM=0"
set "FOUND_VIVADO=0"
set "TOOL_LIST=xsim modelsim vivado"
for %%T in (%TOOL_LIST%) do (
  set "BIN="
  set "VER="
  set "TPAD="
  if /I "%%T"=="modelsim" set "BIN=vsim"
  if /I "%%T"=="vivado"   set "BIN=vivado" & set "TPAD=  "
  if /I "%%T"=="xsim"     set "BIN=xvhdl" & set "TPAD=    "
  where !BIN! >nul 2>&1
  if errorlevel 1 (
    echo %%T!TPAD! : not found
  ) else (
    if /I "%%T"=="modelsim" for /F "delims=" %%V in ('vsim -version') do set "VER=%%V"
    if /I "%%T"=="vivado"   for /F "delims=" %%V in ('vivado -version 2^>^&1 ^| findstr /B /C:"vivado"') do set "VER=%%V"
    if /I "%%T"=="xsim"     for /F "delims=" %%V in ('xvhdl -version 2^>^&1 ^| findstr /B /C:"Vivado Simulator"') do set "VER=%%V"
    if /I "%%T"=="xsim"     set "FOUND_XSIM=1"
    if /I "%%T"=="modelsim" set "FOUND_MODELSIM=1"
    if /I "%%T"=="vivado"   set "FOUND_VIVADO=1"
    echo %%T!TPAD! : !VER!
  )
)
echo.

REM Check the single .f file exists and cache metadata
set "FILE_LIST=%IP_DIR%\%NAME%.f"
if not exist "%FILE_LIST%" (
  echo [run] ERROR: File list '%NAME%.f' not found at %IP_DIR%
  exit /b 1
)
call "%~dp0common\scripts\detect_uvvm.bat" "%FILE_LIST%"
set "META_UVVM_%NAME%=!IS_UVVM!"
call "%~dp0common\scripts\check_top_section.bat" "%FILE_LIST%"
set "META_TOP_%NAME%=!HAS_TOP!"
REM Detect VHDL-2019 files — xsim (Vivado 2023.2) does not support -2019
set "META_V2019_%NAME%=0"
findstr /C:" 2019" "%FILE_LIST%" >nul 2>&1
if not errorlevel 1 set "META_V2019_%NAME%=1"

REM Run each found tool
if "!FOUND_XSIM!"=="1"     call :run_one xsim     %NAME%
if "!FOUND_MODELSIM!"=="1" call :run_one modelsim %NAME%
if "!FOUND_VIVADO!"=="1"   call :run_one vivado   %NAME%

goto :run_summary

REM ===========================================================================
REM Run all batch (non-GUI) permutations.
REM
REM Strategy:
REM   1. Scan available EDA tools on PATH — only iterate over found tools.
REM   2. Pre-compute UVVM and [top] metadata for EVERY .f file in one pass,
REM      storing results in environment variables (META_UVVM_<name> and
REM      META_TOP_<name>). This avoids re-running detect_uvvm.bat and
REM      check_top_section.bat for each tool permutation of the same file.
REM   3. Call :run_one per tool/file combination, reading cached metadata.
REM      This separation is required because CMD's for-loop + call + delayed
REM      expansion has known bugs with nested parenthesized if blocks.
REM
REM Tool exclusions:
REM   xsim  — skips file lists whose [tb] section references "uvvm" (UVVM
REM           libraries are not available in the XSim toolchain).
REM   vivado — skips .f files without a [top] section (simulation-only lists).
REM ===========================================================================
:run_all
set "IP_DIR=%~dp0%IP%\scripts"
if not exist "%IP_DIR%" (
  echo [run] ERROR: IP '%IP%' not found at %IP_DIR%
  exit /b 1
)

set "FAILED=0"
set "PASSED=0"
set "SKIPPED=0"
set "FILE_NAMES="

echo =======================================================================
echo  Running all batch permutations for IP: %IP%
echo =======================================================================

REM Warn if GUI flag is set — not valid with 'all'
if not "%GUI%"=="" (
  echo   [WARN] GUI flag ignored: 'all' mode runs batch only
)
set "GUI="

REM Determine tool set: use %TOOL% if specified, otherwise scan PATH
REM
REM NOTE: Same !VER! echo-placement rule applies here. Version capture
REM happens inside if/else or if/else blocks; echo uses !VER! only after
REM the closing paren to avoid CMD's delayed-expansion parser corruption.
set "FOUND_XSIM=0"
set "FOUND_MODELSIM=0"
set "FOUND_VIVADO=0"
set "TOOL_LIST=xsim modelsim vivado"
if not "%TOOL%"=="" (
  set "TPAD="
  if /I "%TOOL%"=="vivado" set "TPAD=  "
  if /I "%TOOL%"=="xsim"   set "TPAD=    "
  set "VER="
  if /I "%TOOL%"=="modelsim" for /F "delims=" %%V in ('vsim -version') do set "VER=%%V"
  if /I "%TOOL%"=="vivado"   for /F "delims=" %%V in ('vivado -version 2^>^&1 ^| findstr /B /C:"vivado"') do set "VER=%%V"
  if /I "%TOOL%"=="xsim"     for /F "delims=" %%V in ('xvhdl -version 2^>^&1 ^| findstr /B /C:"Vivado Simulator"') do set "VER=%%V"
  if /I "%TOOL%"=="xsim"     set "FOUND_XSIM=1"
  if /I "%TOOL%"=="modelsim" set "FOUND_MODELSIM=1"
  if /I "%TOOL%"=="vivado"   set "FOUND_VIVADO=1"
  echo %TOOL%!TPAD! : !VER!
) else (
  for %%T in (%TOOL_LIST%) do (
    set "BIN="
    set "VER="
    set "TPAD="
    if /I "%%T"=="modelsim" set "BIN=vsim"
    if /I "%%T"=="vivado"   set "BIN=vivado" & set "TPAD=  "
    if /I "%%T"=="xsim"     set "BIN=xvhdl" & set "TPAD=    "
    where !BIN! >nul 2>&1
    if errorlevel 1 (
      echo %%T!TPAD! : not found
    ) else (
      if /I "%%T"=="modelsim" for /F "delims=" %%V in ('vsim -version') do set "VER=%%V"
      if /I "%%T"=="vivado"   for /F "delims=" %%V in ('vivado -version 2^>^&1 ^| findstr /B /C:"vivado"') do set "VER=%%V"
      if /I "%%T"=="xsim"     for /F "delims=" %%V in ('xvhdl -version 2^>^&1 ^| findstr /B /C:"Vivado Simulator"') do set "VER=%%V"
      echo %%T!TPAD! : !VER!
      if /I "%%T"=="xsim"     set "FOUND_XSIM=1"
      if /I "%%T"=="modelsim" set "FOUND_MODELSIM=1"
      if /I "%%T"=="vivado"   set "FOUND_VIVADO=1"
    )
  )
)
echo.

dir /b "%IP_DIR%\*.f" >nul 2>&1
if errorlevel 1 (
  echo [run] ERROR: No .f file lists found under %IP_DIR%
  exit /b 1
)

for %%F in ("%IP_DIR%\*.f") do (
  set "BASE=%%~nF"
  set "FILE_NAMES=!FILE_NAMES! %%~nF"
  call "%~dp0common\scripts\detect_uvvm.bat" "%%~fF"
  set "META_UVVM_%%~nF=!IS_UVVM!"
  call "%~dp0common\scripts\check_top_section.bat" "%%~fF"
  set "META_TOP_%%~nF=!HAS_TOP!"
  REM Detect VHDL-2019 files — xsim (Vivado 2023.2) does not support -2019
  set "META_V2019_%%~nF=0"
  findstr /C:" 2019" "%%~fF" >nul 2>&1
  if not errorlevel 1 set "META_V2019_%%~nF=1"
)

if "!FOUND_XSIM!"=="1" (
  for %%N in (!FILE_NAMES!) do call :run_one xsim %%N
)
if "!FOUND_MODELSIM!"=="1" (
  for %%N in (!FILE_NAMES!) do call :run_one modelsim %%N
)
if "!FOUND_VIVADO!"=="1" (
  for %%N in (!FILE_NAMES!) do call :run_one vivado %%N
)

echo.
goto :run_summary

REM ===========================================================================
REM Summary report — shared by :run_name_all and :run_all
REM ===========================================================================
:run_summary
echo.
echo =======================================================================
echo  SUMMARY
echo =======================================================================
echo -----------------------------------------------------------------------
echo  TOTAL: %PASSED% passed, %FAILED% failed, %SKIPPED% skipped
echo =======================================================================
exit /b %FAILED%

REM -----------------------------------------------------------------------
REM Subroutine: run a single tool/file-list permutation and count result.
REM
REM   %1 = tool name (modelsim / vivado / xsim)
REM   %2 = file list basename (e.g. vhdl, uvvm, sv)
REM
REM Reads pre-computed metadata from META_UVVM_<name> and META_TOP_<name>
REM environment variables using CMD's "call set" trick:
REM   call set "VAR=%%DYNAMIC_ENV_VAR_NAME%%"
REM This forces a second expansion pass at runtime, resolving the variable
REM whose name contains another variable (%FILE_NAME%). Without this, the
REM value would be empty because CMD expands all %var% at parse time.
REM -----------------------------------------------------------------------
:run_one
set "TOOL_NAME=%~1"
set "FILE_NAME=%~2"
call set "IS_UVVM_CACHED=%%META_UVVM_%FILE_NAME%%%"
call set "HAS_TOP_CACHED=%%META_TOP_%FILE_NAME%%%"
call set "HAS_V2019_CACHED=%%META_V2019_%FILE_NAME%%%"

REM Padding for aligned result column (used in skip and run messages)
set "PREF=!TOOL_NAME! !FILE_NAME!                              "
set "PREF=!PREF:~0,24!"

REM --- xsim UVVM skip ---
REM XSim does not ship with UVVM libraries, so UVVM testbenches
REM must be redirected to ModelSim/Questa.
REM
REM CMD BUG WORKAROUND: Each condition must be on its own separate
REM `if` statement. DO NOT merge them into a parenthesized block:
REM   if "%TOOL_NAME%"=="xsim" (
REM     if "%IS_UVVM_CACHED%"=="1" ...
REM   )
REM CMD 10.0.* (Windows 10/11) has a confirmed bug where delayed-expansion
REM variables inside parenthesized `if` blocks, when invoked via `call :sub`
REM from within a `for` loop, silently exit the subroutine after the block
REM when the outer condition is FALSE. The only reliable workaround is to
REM keep each condition flat: one `if` per line.
if /I "%TOOL_NAME%"=="xsim" if "%IS_UVVM_CACHED%"=="1" echo !PREF![SKIP] (UVVM not supported)
if /I "%TOOL_NAME%"=="xsim" if "%IS_UVVM_CACHED%"=="1" set /a SKIPPED+=1
if /I "%TOOL_NAME%"=="xsim" if "%IS_UVVM_CACHED%"=="1" goto :eof

REM --- xsim VHDL-2019 skip ---
REM XSim (Vivado 2023.2) does not support VHDL-2019. File lists with
REM " 2019" suffix entries must be redirected to Questa/ModelSim.
if /I "%TOOL_NAME%"=="xsim" if "%HAS_V2019_CACHED%"=="1" echo !PREF![SKIP] (VHDL-2019 not supported)
if /I "%TOOL_NAME%"=="xsim" if "%HAS_V2019_CACHED%"=="1" set /a SKIPPED+=1
if /I "%TOOL_NAME%"=="xsim" if "%HAS_V2019_CACHED%"=="1" goto :eof

REM --- vivado [top] skip ---
REM Synthesis requires a top-level wrapper in the [top] section.
REM Simulation-only file lists (e.g. uvvm.f) have no [top] section
REM and must be skipped here to avoid Vivado compile errors.
REM Same CMD bug avoidance applies — flat if statements only.
if /I "%TOOL_NAME%"=="vivado" if not "%HAS_TOP_CACHED%"=="1" echo !PREF![SKIP] (no [top] section)
if /I "%TOOL_NAME%"=="vivado" if not "%HAS_TOP_CACHED%"=="1" set /a SKIPPED+=1
if /I "%TOOL_NAME%"=="vivado" if not "%HAS_TOP_CACHED%"=="1" goto :eof


REM Print name immediately (no newline), then run, then append result
set /P "=!PREF!"<nul

cd /d "%IP_DIR%"

if /I "%TOOL_NAME%"=="modelsim" (
  call ..\..\common\scripts\simulate.bat "%CD%" %FILE_NAME% >nul 2>&1
) else if /I "%TOOL_NAME%"=="vivado" (
  call ..\..\common\scripts\synthesize.bat "%CD%" %FILE_NAME% >nul 2>&1
) else if /I "%TOOL_NAME%"=="xsim" (
  call ..\..\common\scripts\simulate_xsim.bat "%CD%" %FILE_NAME% >nul 2>&1
)

if %ERRORLEVEL% equ 0 (
  echo [PASS]
  set /a PASSED+=1
) else (
  echo [FAIL]
  set /a FAILED+=1
)
exit /b 0

:usage
echo Usage: run ^<ip^> ^<name^> [^<tool^>] [gui]
echo        run ^<ip^> ^<name^>               all tools (scan PATH)
echo        run ^<ip^> all [^<tool^>]         all .f files
echo        run ^<ip^> clean
echo Tools: modelsim vivado xsim
exit /b 1
