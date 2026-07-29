@echo off
setlocal enabledelayedexpansion

set "SCRIPTS_DIR=%~1"
set "NAME=%~2"
set "GUI=%~3"

if /I "%NAME%"=="clean" (
  if exist "%SCRIPTS_DIR%\..\xsim" rmdir /s /q "%SCRIPTS_DIR%\..\xsim" 2>nul
  echo [simulate_xsim] Done. & exit /b 0
)
if "%NAME%"=="" echo [simulate_xsim] ERROR: Missing arguments. & exit /b 1

for %%I in ("%SCRIPTS_DIR%\..") do set "IP_NAME=%%~nxI"
for %%I in ("%SCRIPTS_DIR%\..\..") do set "FPGA_IP_ROOT=%%~fI"

set "FILE_LIST=%SCRIPTS_DIR%\%NAME%.f"
if not exist "%FILE_LIST%" echo [simulate_xsim] ERROR: File list not found: %FILE_LIST% & exit /b 1

call "%SCRIPTS_DIR%\..\..\common\scripts\detect_uvvm.bat" "%FILE_LIST%"
if %IS_UVVM% equ 1 (
  echo [simulate_xsim] SKIPPING: UVVM testbenches require ModelSim/Questa ^(UVVM libraries not available in XSim^).
  exit /b 0
)

REM --- Parse top testbench entity from [tb] section of .f file ---
REM Reads the first non-comment line after `# [tb]`, extracts the entity
REM name from that VHDL file. Falls back to <ip_name>_tb if not found.
set "FILE_LIST_WIN=%FILE_LIST:/=\%"
set "TB_REL="
for /F "tokens=*" %%L in (%FILE_LIST_WIN%) do (
  set "LINE=%%L"
  if "!LINE!"=="# [tb]" set "TB_SECTION=1"
  if defined TB_SECTION (
    if not "!LINE!"=="" if not "!LINE:~0,1!"=="#" if not "!LINE!"=="# [tb]" (
      set "TB_REL=!LINE!"
      goto :got_tb
    )
  )
)
:got_tb
if defined TB_REL (
  set "TB_REL=!TB_REL:/=\!"
  set "TB_ABS=%FPGA_IP_ROOT%\!TB_REL!"
  for /F "tokens=2" %%E in ('findstr /I /B "entity" "!TB_ABS!" 2^>nul') do (
    set "TOP_TB=%%E"
  )
)
if not defined TOP_TB (
  set "TOP_TB=%IP_NAME%_tb"
)
echo [simulate_xsim] Top testbench entity: !TOP_TB!

set "SIM_DIR=%SCRIPTS_DIR%\..\xsim"
if exist "%SIM_DIR%" rmdir /s /q "%SIM_DIR%" 2>nul
mkdir "%SIM_DIR%" 2>nul

echo [simulate_xsim] Compiling from %FILE_LIST%...

cd /d "%SIM_DIR%"

REM --- Compile each source in .f order ---
REM The .f file is author-controlled, so dependency order is preserved.
REM Sources are listed top-to-bottom; the compiler processes them in that
REM sequence (a package must appear before its consumers).
REM
REM PIPE DEADLOCK WORKAROUND: We read the .f file with `for /F ... in ("file")`
REM instead of piping to findstr/grep. CMD's pipe implementation creates
REM async subprocesses that deadlock on the console handle when stdout
REM is redirected to nul (as happens in run_all mode via >nul 2>&1).
REM Reading line-by-line avoids pipes entirely. See user memory for details.
for /F "usebackq tokens=* delims=" %%L in ("%FILE_LIST%") do (
  set "LINE=%%L"
  set "FIRST=!LINE:~0,1!"
  REM Skip blank, comment, and section-header lines
  if not "!LINE!"=="" if not "!FIRST!"=="#" if not "!FIRST!"=="[" (
    for /F "tokens=1,2 delims= " %%A in ("!LINE!") do (
      set "SRC=%%A"
      set "STD=%%B"
      set "EXT="
      for %%E in ("%%A") do set "EXT=%%~xE"
      if /I "!EXT!"==".sv" (
        echo [simulate_xsim] Compiling SystemVerilog: %%A
        call xvlog -sv --work work "%FPGA_IP_ROOT%\%%A"
        if !errorlevel! neq 0 exit /b !errorlevel!
      ) else if /I "!EXT!"==".vhd" (
        REM --- VHDL standard selection ---
        REM The .f file may include an optional VHDL standard suffix
        REM after the file path (e.g. "tb/foo.vhd 93"). We dispatch
        REM on that suffix to pass the correct --93/--2008/--2019 flag
        REM to xvhdl. Missing suffix defaults to --2008.
        REM
        REM Note: .vhd and .vhdl are handled in separate blocks because
        REM CMD's for-loop structure forces us to check extensions inside
        REM nested else-if chains — there's no clean way to consolidate
        REM the VHDL standard logic across both extensions in batch.
        REM
        REM The `call` prefix before xvhdl/xvlog is REQUIRED: these are
        REM themselves .bat wrappers, and without `call`, they REPLACE
        REM the calling CMD process, preventing cleanup code from running.
        if "!STD!"=="93" (
          echo [simulate_xsim] Compiling VHDL-93: %%A
          call xvhdl --93 --work work "%FPGA_IP_ROOT%\%%A"
        ) else if "!STD!"=="2019" (
          echo [simulate_xsim] Compiling VHDL-2019: %%A
          call xvhdl --2019 --work work "%FPGA_IP_ROOT%\%%A"
        ) else (
          echo [simulate_xsim] Compiling VHDL-2008: %%A
          call xvhdl --2008 --work work "%FPGA_IP_ROOT%\%%A"
        )
        if !errorlevel! neq 0 exit /b !errorlevel!
      ) else if /I "!EXT!"==".vhdl" (
        REM Same VHDL standard logic as .vhd above. Kept as a separate
        REM branch because CMD for-loops require explicit extension checks.
        if "!STD!"=="93" (
          echo [simulate_xsim] Compiling VHDL-93: %%A
          call xvhdl --93 --work work "%FPGA_IP_ROOT%\%%A"
        ) else if "!STD!"=="2019" (
          echo [simulate_xsim] Compiling VHDL-2019: %%A
          call xvhdl --2019 --work work "%FPGA_IP_ROOT%\%%A"
        ) else (
          echo [simulate_xsim] Compiling VHDL-2008: %%A
          call xvhdl --2008 --work work "%FPGA_IP_ROOT%\%%A"
        )
        if !errorlevel! neq 0 exit /b !errorlevel!
      ) else (
        echo [simulate_xsim] WARNING: Skipping unsupported file: %%A
      )
    )
  )
)

REM --- Elaboration ---
REM xelab links all compiled units into a simulation snapshot. This is
REM the step that resolves top-level entity bindings and reports missing
REM component/libraries as elaboration-time errors. If this fails, the
REM design cannot be simulated and we exit immediately.
echo [simulate_xsim] Elaborating %TOP_TB%...
call xelab %TOP_TB%
if %errorlevel% neq 0 (
  echo [simulate_xsim] ERROR: Elaboration failed.
  exit /b %errorlevel%
)

REM --- Run simulation ---
REM Two modes:
REM   GUI:  start /B lauches xsim --gui as a background process so the
REM         terminal stays available. The GUI includes the waveform viewer.
REM   Batch: xsim --runall runs all testbench transactions to completion
REM         and exits with pass/fail status visible in the console output.
REM
REM Note: In batch mode, we omit "work." prefix because xsim's default
REM library search resolves it from the xsim.dir/ snapshot automatically.
REM In GUI mode we keep the full "work." qualifier for clarity.
if /I "%GUI%"=="gui" (
  echo [simulate_xsim] Opening %NAME% testbench ^(GUI^)...
  start /B "" xsim work.%TOP_TB% --gui
) else (
  echo [simulate_xsim] Running %NAME% testbench ^(batch^)...
  call xsim %TOP_TB% --runall
)
