@echo off
REM ===========================================================================
REM sim.bat — Thin wrapper delegating to run.bat
REM
REM Usage:
REM   sim                Batch, vhdl.f (default)
REM   sim sv.f           Batch, custom sv.f
REM   sim -gui           GUI mode with waveform
REM   sim sv.f -gui      GUI mode, custom sv.f
REM
REM Prerequisite: Initialize EDA tool first (see fpga-rules/README.md).
REM ===========================================================================
cd /d "%~dp0"
set NAME=%~n1
if "%NAME%"=="" set NAME=vhdl
if "%2"=="-gui" (call ..\..\run %NAME% modelsim gui) else (call ..\..\run %NAME% modelsim)
