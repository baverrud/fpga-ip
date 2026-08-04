@echo off
REM ===========================================================================
REM sim.bat -- Launch vsim with sim.do
REM
REM Prerequisite: Initialize EDA tool first (see fpga-rules/README.md).
REM
REM Usage:
REM   sim           Launch GUI with waveform viewer
REM   sim -c        Launch batch (headless) mode
REM ===========================================================================
cd /d "%~dp0"
vsim %1 -do sim.do
