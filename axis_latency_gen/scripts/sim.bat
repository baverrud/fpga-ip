@echo off
REM ===========================================================================
REM sim.bat — Launch vsim with sim.do
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

set GUIMODE=0
set FNAME=

:parse
if "%1"=="" goto :run
if "%1"=="-gui" set GUIMODE=1
set ARG=%1
if /I "%ARG:~-2%"==".f" set FNAME=%ARG%
shift
goto :parse

:run
if %GUIMODE%==1 (
    if defined FNAME ( vsim -do "set files %FNAME%; do sim.do"
    ) else (          vsim -do sim.do )
) else (
    if defined FNAME ( vsim -c -do "set files %FNAME%; do sim.do"
    ) else (          vsim -c -do sim.do )
)
