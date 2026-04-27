@echo off
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -NoLogo -File "Check-TarkovPrices.ps1"
pause