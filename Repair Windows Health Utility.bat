@echo off
setlocal EnableExtensions
pushd "%~dp0" 2>nul || (
    echo Failed to change to script directory: "%~dp0"
    pause
    exit /b 1
)
if not exist "%~dp0Repair-WindowsHealthUtility.ps1" (
    echo Script file not found: "%~dp0Repair-WindowsHealthUtility.ps1"
    pause
    exit /b 1
)
where powershell.exe >nul 2>&1 || (
    echo powershell.exe not found in PATH
    pause
    exit /b 1
)
powershell.exe -NoProfile -Command "Unblock-File -LiteralPath '%~dp0Repair-WindowsHealthUtility.ps1' -ErrorAction SilentlyContinue"
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0Repair-WindowsHealthUtility.ps1" %*
set "WHU_EXIT=%errorlevel%"
popd
endlocal & exit /b %WHU_EXIT%