@echo off
chcp 65001 >nul
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "src\probe.ps1"
echo.
echo [program ended]
pause
