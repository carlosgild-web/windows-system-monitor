#Requires -Version 5.1
<#
.SYNOPSIS
    Terminates every active monitoring script launched by start_monitoring.bat.
.DESCRIPTION
    Queries Win32_Process for powershell.exe instances whose command line
    matches any known monitor script name, then stops them.
    Called by stop_monitoring.bat — do not run this script on its own
    if you want the formatted bat window output.
#>

$ErrorActionPreference = 'SilentlyContinue'

# Scripts managed by start_monitoring.bat (name without extension)
$MONITOR_SCRIPTS = @(
    'process_monitor',
    'performance_monitor',
    'monitor_disk',
    'monitor_network',
    'monitor_document',
    'monitor_ebook_sales',      # v1.5 name; still stopped so an upgrade leaves nothing behind
    'monitoring_console'
)

# ─── Helpers ──────────────────────────────────────────────────────────────────
function Write-Line ([string]$text, [ConsoleColor]$color = 'Gray') {
    Write-Host $text -ForegroundColor $color
}

# ─── Discover running monitor processes ───────────────────────────────────────
Write-Line "  Scanning for active monitoring processes..." Gray
$allPs  = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' AND ProcessId!=$PID" -ErrorAction SilentlyContinue)
$allPs += @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' AND ProcessId!=$PID"       -ErrorAction SilentlyContinue)
$allPs += @(Get-CimInstance Win32_Process -Filter "Name='python.exe'"   -ErrorAction SilentlyContinue)
$allPs += @(Get-CimInstance Win32_Process -Filter "Name='pythonw.exe'"  -ErrorAction SilentlyContinue)

$found = [System.Collections.Generic.List[object]]::new()

foreach ($scriptName in $MONITOR_SCRIPTS) {
    $hits = @($allPs | Where-Object { $_.CommandLine -like "*$scriptName*" })
    foreach ($proc in $hits) {
        $found.Add([pscustomobject]@{
            Script = $scriptName
            PID    = $proc.ProcessId
        })
    }
}

# The settings editor (server.py), e.g. started hidden by the console's "Open Monitoring
# settings" button. Matched on this project's full path: "server.py" alone is too common.
$editorPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'server.py'
foreach ($proc in @($allPs | Where-Object { $_.Name -like 'python*' -and $_.CommandLine -and
        $_.CommandLine.IndexOf($editorPath, [StringComparison]::OrdinalIgnoreCase) -ge 0 })) {
    $found.Add([pscustomobject]@{ Script = 'settings editor'; PID = $proc.ProcessId })
}

# ─── Nothing to stop ──────────────────────────────────────────────────────────
if ($found.Count -eq 0) {
    Write-Host ""
    Write-Line "  No active monitoring processes found." Yellow
    return
}

# ─── Stop each process ────────────────────────────────────────────────────────
Write-Host ""
$stopped = 0
$failed  = 0

$stoppedPids = [System.Collections.Generic.List[int]]::new()

foreach ($item in $found) {
    try {
        Stop-Process -Id $item.PID -Force -ErrorAction Stop
        Write-Line "  [STOPPED]  $($item.Script)   (PID $($item.PID))" Red
        $stoppedPids.Add($item.PID)
        $stopped++
    }
    catch {
        Write-Line "  [FAILED ]  $($item.Script)   (PID $($item.PID)) - $_" Yellow
        $failed++
    }
}

# Wait for every stopped process to fully exit before returning.
# Without this, WMI still returns dying processes as running for a brief
# window, so the launcher could report them as still running.
# Note: the loop variable must NOT be named $pid -- $PID is a read-only
# automatic variable, and assigning to it silently skips the whole loop.
if ($stoppedPids.Count -gt 0) {
    Write-Host ""
    Write-Line "  Waiting for processes to exit..." Gray
    foreach ($procId in $stoppedPids) {
        try { Wait-Process -Id $procId -Timeout 10 -ErrorAction SilentlyContinue } catch {}
    }
}

# (Excel is not handled here: the document monitor reads workbooks in a short-lived
# child process, Read-XlsxTotal.ps1, which is not stopped and exits on its own,
# so Excel always shuts down cleanly.)

# ─── Summary ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Line "  --------------------------------" DarkGray

if ($stopped -gt 0) {
    Write-Line "  Stopped : $stopped process(es)" Green
}
if ($failed -gt 0) {
    Write-Line "  Failed  : $failed process(es)" Yellow
}
Write-Line "  All monitors are now inactive." Green
