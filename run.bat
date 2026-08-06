@echo off
REM ===========================================================================
REM run.bat -- Thin Windows entry point for the new run.py runner
REM
REM Usage:
REM   run <ip> <manifest> <tool> [--tb <testbench>] [mode]
REM   run clean <ip>
REM
REM Examples:
REM   run axis_fifo vhdl modelsim
REM   run axis_fifo vhdl modelsim --tb default
REM   run axis_fifo vhdl vivado project
REM   run axis_fifo vhdl xsim gui
REM   run clean axis_fifo
REM
REM run.py is the only launcher (the legacy run_legacy.bat / common/scripts
REM stack was removed after the migration).
REM ===========================================================================
python "%~dp0run.py" %*
exit /b %ERRORLEVEL%
