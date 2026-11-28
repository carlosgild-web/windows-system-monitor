#Requires -Version 5.1
<#
.SYNOPSIS
    Video mode: start the test environment from a clean scratch copy, with the incident assistant on.
.DESCRIPTION
    start_monitoring.bat video   (or: powershell -File scripts\video_mode.ps1 [-Path <dir>] [-Model <tag>])

    Used to record the showcase GIF and video (docs/video.md). Every start is the same:
      1. Refuses to run while ports 5757/5758 are in use: stop the running copy first
         (stop_monitoring.bat), so the recording never shows another copy's logs.
      2. Makes a fresh copy of the runtime files in -Path (default %TEMP%\wsm-video) with an empty
         logs folder: no old incidents, tickets start at INC0010001, no email cooldowns, no traces.
         A previous copy is deleted only if it carries this script's marker file.
      3. Turns the assistant on in the copy's settings (ai.enabled, and -Model if given).
         This project's own monitoring_settings.json is not changed.
      4. Runs the copy's own launcher (preflight, monitors, console).
    Stop it with stop_monitoring.bat in the copy (the path is printed at the end).
#>
param(
    [string]$Path = (Join-Path $env:TEMP 'wsm-video'),
    [string]$Model = ''
)
$ErrorActionPreference = 'Stop'

$root   = Split-Path $PSScriptRoot -Parent
$marker = '.wsm-video-copy'

function Write-Step ([string]$Text, [ConsoleColor]$Color = 'Cyan') { Write-Host "  $Text" -ForegroundColor $Color }

Write-Host ''
Write-Step 'Video mode: a clean copy of the test environment, with the incident assistant on'
Write-Host ''

# 1. Ports
$busy = @(5757, 5758 | Where-Object { Get-NetTCPConnection -LocalPort $_ -State Listen -ErrorAction SilentlyContinue })
if ($busy.Count -gt 0) {
    Write-Step ("Port(s) {0} are in use: another copy of the console or editor is running." -f ($busy -join ', ')) Red
    Write-Step 'Run stop_monitoring.bat in that copy first, then start video mode again.' DarkGray
    exit 1
}

# 2. Fresh copy
$full = [System.IO.Path]::GetFullPath($Path)
if ($full.TrimEnd('\') -eq $root.TrimEnd('\') -or $root.StartsWith($full.TrimEnd('\') + '\')) {
    Write-Step "Refusing to use ${full}: it is (or contains) this project." Red
    exit 1
}
if (Test-Path $full) {
    if (-not (Test-Path (Join-Path $full $marker))) {
        Write-Step "$full exists and was not made by video mode; choose another -Path." Red
        exit 1
    }
    Remove-Item $full -Recurse -Force
}
New-Item -ItemType Directory -Path $full -Force | Out-Null
Set-Content -Path (Join-Path $full $marker) -Value 'Made by scripts\video_mode.ps1; safe to delete.' -Encoding ASCII

# Runtime files only: no logs, tests, docs, evaluation, media tooling or git data.
$exclude = @('.git', '.github', 'logs', 'tests', 'docs', 'eval', 'e2e', 'video', 'art', 'docker', 'tools',
             '__pycache__', 'node_modules')
$null = robocopy $root $full /E /XD @($exclude | ForEach-Object { Join-Path $root $_ }) __pycache__ node_modules `
        /XF *.pyc /NFL /NDL /NJH /NJS /NP
if ($LASTEXITCODE -ge 8) { Write-Step "Copy failed (robocopy exit $LASTEXITCODE)." Red; exit 1 }
New-Item -ItemType Directory -Path (Join-Path $full 'logs') -Force | Out-Null
Write-Step "[  OK  ]  Clean copy: $full" Green

# 3. Assistant on, in the copy only. Python edits the JSON, so its formatting stays as the editor writes it.
$settings = Join-Path $full 'monitoring_settings.json'
# No double quotes in this code: Windows PowerShell 5.1 strips them from native-command arguments.
$py = @'
import json, sys
path, model = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else '')
with open(path, encoding='utf-8-sig') as f:
    cfg = json.load(f)
ai = cfg.setdefault('ai', {})
ai['enabled'] = True
if model:
    ai['model'] = model
with open(path, 'w', encoding='utf-8', newline=chr(10)) as f:
    f.write(json.dumps(cfg, indent=2, ensure_ascii=False) + chr(10))
print(ai.get('model'))
'@
$usedModel = & python -c $py $settings $Model
if ($LASTEXITCODE -ne 0) { Write-Step 'Could not update the copy''s settings.' Red; exit 1 }
Write-Step "[  OK  ]  Assistant on in the copy (model: $usedModel)" Green
Write-Host ''

# 4. The copy's own launcher
& powershell.exe -ExecutionPolicy Bypass -NoProfile -File (Join-Path $full 'scripts\start_monitoring.ps1')
$code = $LASTEXITCODE
Write-Host ''
Write-Step "Video copy: $full" DarkGray
Write-Step "Stop it with: `"$full\stop_monitoring.bat`"" DarkGray
exit $code
