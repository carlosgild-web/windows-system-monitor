@echo off
cd /d "%~dp0"
rem "start_monitoring.bat video": a clean scratch copy with the incident assistant on (docs/video.md)
if /i "%~1"=="video" (
  powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0scripts\video_mode.ps1"
  goto :eof
)
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0scripts\start_monitoring.ps1"
