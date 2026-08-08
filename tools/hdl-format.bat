@echo off
REM hdl-format.bat -- PATH-friendly launcher for hdl-format.py
python "%~dp0hdl-format.py" %*
exit /b %ERRORLEVEL%
