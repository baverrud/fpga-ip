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
REM The old launcher is preserved at run_legacy.bat during migration.
REM ===========================================================================
python "%~dp0run.py" %*
exit /b %ERRORLEVEL%
