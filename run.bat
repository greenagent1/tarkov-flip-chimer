@echo off
cd /d "%~dp0"
where pwsh >nul 2>&1
if %errorlevel%==0 (
    pwsh -ExecutionPolicy Bypass -NoLogo -File "Check-TarkovPrices.ps1"
) else (
    powershell -ExecutionPolicy Bypass -NoLogo -File "Check-TarkovPrices.ps1"
)
pause
