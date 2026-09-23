@echo off
REM Launcher for Fire TV Sideload — starts the PowerShell GUI with no console window
REM and no execution-policy friction.
cd /d "%~dp0"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Sideload.ps1"
