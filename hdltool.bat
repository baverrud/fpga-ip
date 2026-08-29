@echo off
REM Location-independent launcher for tools/hdltool.py.
python "%~dp0tools\hdltool.py" %*
exit /b %ERRORLEVEL%
