@echo off
REM ===========================================================================
REM hdl-format.bat -- PATH-friendly launcher for hdl-format.py
REM
REM Usage:
REM   hdl-format [options] <file> [<file> ...]
REM
REM Add this directory to your Windows PATH to call the formatter from any
REM working directory, e.g.:
REM
REM   hdl-format --style moderate --dry-run path/to/file.vhd
REM
REM Relative input paths are resolved from the caller's current directory,
REM not from the location of this batch file.
REM ===========================================================================

REM @echo off (first line) suppresses echoing of each subsequent command, so
REM the batch file runs quietly and only the formatter's own output is shown.

REM %~dp0 expands to the drive letter and directory path of THIS batch file,
REM including a trailing backslash, e.g.:
REM   C:\path\to\fpga-ip\tools\
REM It makes the launcher location-independent: whichever directory the user
REM invokes it from, the .py script is found next to the .bat file. The
REM surrounding quotes keep the path intact even when it contains spaces.

REM %* forwards ALL arguments given to the batch file, unchanged, to the
REM Python script.

python "%~dp0hdl-format.py" %*

REM exit /b ends only this batch script (not the whole cmd.exe process), so a
REM script that calls hdl-format can continue afterwards. %ERRORLEVEL% holds
REM the exit code of the most recent command; propagating it means the batch
REM file's exit status matches Python's (e.g. 1 when --check found formatting
REM needed, 0 on success or no changes).
exit /b %ERRORLEVEL%
