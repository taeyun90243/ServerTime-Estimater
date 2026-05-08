@echo off
chcp 65001 >nul
cd /d "%~dp0"
python clicker_gui.py
echo.
echo [clicker gui ended]
pause
