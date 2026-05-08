@echo off
chcp 65001 >nul
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "clicker.ps1" %*
echo.
echo [clicker ended]
pause
