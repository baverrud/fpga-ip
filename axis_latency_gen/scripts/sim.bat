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
for %%I in ("%~dp0..") do set "IP=%%~nxI"
set NAME=%~n1
if "%NAME%"=="" set NAME=vhdl
if "%NAME:~0,1%"=="-" set NAME=vhdl
if "%2"=="-gui" (vsim -do "set files %NAME%.f; do sim.do") else (vsim -c -do "set files %NAME%.f; do sim.do")
