@echo off
chcp 65001 >nul
cd /d "%~dp0..\.."
python -m PyInstaller --noconfirm --onefile --console --name ServerTimeProbe --distpath "." --workpath "tools\build-artifacts\server-time-probe\build" --specpath "tools\build-artifacts\server-time-probe" "tools\server-time-probe-exe\run_launcher.py"
echo.
echo Build output: ServerTimeProbe.exe
pause
