@echo off
chcp 65001 >nul
cd /d "%~dp0"
python -m PyInstaller --noconfirm --onefile --windowed --name ServerTimeClicker --distpath "dist" --workpath "..\..\tools\build-artifacts\auto-clicker-gui\build" --specpath "..\..\tools\build-artifacts\auto-clicker-gui" clicker_gui.py
echo.
echo Build output: dist\ServerTimeClicker.exe
pause
