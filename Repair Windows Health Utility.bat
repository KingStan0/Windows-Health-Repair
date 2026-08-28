@echo off
setlocal
cd /d "%~dp0"
if not exist "%~dp0Repair-WindowsHealthUtility.ps1" (
    echo Script file not found: %~dp0Repair-WindowsHealthUtility.ps1
    pause
    exit /b 1
)
powershell.exe -NoProfile -Command "Unblock-File -LiteralPath ""%~dp0Repair-WindowsHealthUtility.ps1"" -ErrorAction SilentlyContinue"
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0Repair-WindowsHealthUtility.ps1" %*
endlocal