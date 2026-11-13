@echo off
setlocal
title Stop Monitoring
cd /d "%~dp0"
color 0C

echo.
echo  ================================================
echo   Monitoring Solution  ^|  Stopping all monitors
echo  ================================================
echo.

powershell -ExecutionPolicy Bypass -NoProfile ^
    -File "%~dp0scripts\stop_monitoring.ps1"

echo.
echo  ================================================
echo   All monitoring processes have been stopped.
echo  ================================================
echo.
pause
endlocal
