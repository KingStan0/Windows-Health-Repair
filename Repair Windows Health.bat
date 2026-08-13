@echo off
cd /d "%~dp0"
if not exist "%~dp0Repair-WindowsHealth.ps1" (
    echo Script file not found: %~dp0Repair-WindowsHealth.ps1
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Repair-WindowsHealth.ps1"