@echo off
title Monitoring Doctor
cd /d "%~dp0"
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0scripts\doctor.ps1" %*
pause
