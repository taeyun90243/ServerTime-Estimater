@echo off
chcp 65001 >nul
cd /d "%~dp0"
where pwsh >nul 2>nul
if %errorlevel%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "src\probe.ps1"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "src\probe.ps1"
)
echo.
echo [program ended]
pause
