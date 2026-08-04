@echo off
REM ===========================================================================
REM sim.bat -- Thin wrapper delegating to run.bat
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
set NAME=vhdl
set GUIFLAG=
if /I "%1"=="-gui" set GUIFLAG=-gui
if /I "%2"=="-gui" set GUIFLAG=-gui
if /I "%~x1"==".f" set NAME=%~n1
if /I "%~x2"==".f" set NAME=%~n2
if "%GUIFLAG%"=="-gui" (vsim -do "set files %NAME%.f; do sim.do") else (vsim -c -do "set files %NAME%.f; do sim.do")
