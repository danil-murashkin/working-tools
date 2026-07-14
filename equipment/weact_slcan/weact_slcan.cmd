@echo off
REM Launcher for weact_slcan.ps1 (Windows 11). Default port: COM12.
setlocal
set "SCRIPT_DIR=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%weact_slcan.ps1" %*
