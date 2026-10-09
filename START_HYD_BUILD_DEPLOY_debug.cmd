@echo off
rem Troubleshooting launcher: keeps the console window open so startup errors are visible.
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0HYD_Build_Deploy_GUI.ps1"
if errorlevel 1 (
  echo.
  echo GUI failed to start. Press any key to close.
  pause >nul
)
endlocal
