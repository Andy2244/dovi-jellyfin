@echo off
REM Double-click/cmd entry point for setup.ps1 (a bare .ps1 isn't runnable from cmd).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
pause
