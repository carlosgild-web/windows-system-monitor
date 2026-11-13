#Requires -Version 5.1
<#
.SYNOPSIS
    Process Monitor -- watches every process defined under "processes" in monitoring_settings.json.
.DESCRIPTION
    Runs continuously. Checks each configured process on its own check_interval_sec.
    On the running->NOT-running transition all on_not_running actions fire (popup, log, email, script).
    On subsequent checks while still down only log_to_file and run_script repeat (popup/email suppressed).
    Writes a JSON state file (logs\process_state.json) after every check cycle so the
    MonitoringConsole can display live data without polling the process list itself.

.PARAMETER SettingsFile
    Path to monitoring_settings.json. Default: one level above the script folder.
.PARAMETER StateFile
    Path where the live state JSON is written. Default: logs\process_state.json.
#>
param(
    [string]$SettingsFile = (Join-Path $PSScriptRoot '..\monitoring_settings.json'),
    [string]$StateFile    = (Join-Path $PSScriptRoot '..\logs\process_state.json')
)

$ErrorActionPreference = 'Continue'

# ---- Settings ----------------------------------------------------------------
# Get-MonitorSettings: UTF-8 load + project-relative path resolution
. (Join-Path $PSScriptRoot 'lib\MonitorCommon.ps1')
# Expand-Template / Write-MonitorLog / Invoke-MonitorActions: the shared alert actions
. (Join-Path $PSScriptRoot 'lib\MonitorActions.ps1')
$script:MonitorActionTrace = $true   # this monitor can run in a visible console: print each action

# ---- Console logger ----------------------------------------------------------
function Write-Log ([string]$Message, [ConsoleColor]$Color = 'Gray') {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $Color
}

# ---- State file writer -------------------------------------------------------
function Write-StateFile ($Processes, $State) {
    try {
        $data = [ordered]@{
            updated     = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            monitor_pid = $PID
            processes   = @(
                $Processes | ForEach-Object {
                    $ps = $State[$_.name]
                    [ordered]@{
                        name         = $_.name
                        display_name = $_.display_name
                        required     = $_.required
                        is_running   = $ps.Running
                        last_check   = $ps.LastChecked.ToString('yyyy-MM-dd HH:mm:ss')
                        down_since   = if ($ps.DownSince) { $ps.DownSince.ToString('yyyy-MM-dd HH:mm:ss') } else { $null }
                        alert_count  = $ps.AlertCount
                    }
                }
            )
        }
        $dir = Split-Path $StateFile -Parent
        if ($dir -and -not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $data | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8
    }
    catch { Write-Log "Could not write state file: $_" DarkGray }
}

# ==============================================================================
#  MAIN
# ==============================================================================
try   { $settings = Get-MonitorSettings $SettingsFile }
catch { Write-Host "ERROR: $_" -ForegroundColor Red; exit 1 }

$cfg       = $settings.global
$processes = @($settings.processes)

if ($processes.Count -eq 0) {
    Write-Host 'No processes configured. Exiting.' -ForegroundColor Yellow
    exit 0
}

# Banner
Write-Host ''
Write-Host '  ====================================' -ForegroundColor Cyan
Write-Host '     Process Monitor                  ' -ForegroundColor Cyan
Write-Host '  ====================================' -ForegroundColor Cyan
Write-Host "  Settings : $((Resolve-Path $SettingsFile).Path)" -ForegroundColor DarkGray
Write-Host "  State    : $StateFile" -ForegroundColor DarkGray
Write-Host "  Log      : $($cfg.log_file)" -ForegroundColor DarkGray
Write-Host ''
Write-Host "  Watching $($processes.Count) process(es):" -ForegroundColor White
foreach ($proc in $processes) {
    $tag = if ($proc.required) { 'required' } else { 'optional' }
    Write-Host "    * $($proc.display_name) ($($proc.name))  [$tag, every $($proc.check_interval_sec)s]" -ForegroundColor Gray
}
Write-Host ''
Write-Host '  Press Ctrl+C to stop.' -ForegroundColor DarkGray
Write-Host ''

# Per-process state
$state = @{}
foreach ($proc in $processes) {
    $exe       = $proc.name -replace '(?i)\.exe$', ''
    $isRunning = [bool]@(Get-Process -Name $exe -ErrorAction SilentlyContinue)
    $label     = if ($isRunning) { 'RUNNING' } else { 'NOT RUNNING' }
    $clr       = if ($isRunning) { 'Green' } else { 'Red' }
    Write-Host "  Initial state  $($proc.display_name): $label" -ForegroundColor $clr
    $state[$proc.name] = @{
        Running     = $true           # treat as "was running" so first down-check fires actions
        LastChecked = [DateTime]::MinValue
        DownSince   = $null
        AlertCount  = 0
    }
}
Write-Host ''

# Write initial state so the console can show data immediately
Write-StateFile $processes $state

# Main loop
try {
    while ($true) {
        $now       = Get-Date
        $stateChanged = $false

        foreach ($proc in $processes) {
            try {
                $ps       = $state[$proc.name]
                $interval = [int]$proc.check_interval_sec

                if (($now - $ps.LastChecked).TotalSeconds -lt $interval) { continue }
                $ps.LastChecked = $now

                $exe       = $proc.name -replace '(?i)\.exe$', ''
                $isRunning = [bool]@(Get-Process -Name $exe -ErrorAction SilentlyContinue)

                # Transition: running -> NOT running
                if (-not $isRunning -and $ps.Running) {
                    $ps.Running    = $false
                    $ps.DownSince  = $now
                    $ps.AlertCount = 0
                    $stateChanged  = $true
                    Write-Log "$($proc.display_name) ($($proc.name)) stopped -- firing actions" Red
                    if ($proc.required) {
                        $vars = @{ timestamp = $now.ToString('yyyy-MM-dd HH:mm:ss'); hostname = $env:COMPUTERNAME; proc_name = $proc.name; proc_display = $proc.display_name }
                        Invoke-MonitorActions -Actions $proc.actions.on_not_running -Vars $vars -GlobalCfg $cfg -SuppressSpam:$false -AlertKey "process|$($proc.name)"
                        $ps.AlertCount++
                    }
                }
                # Still NOT running (ongoing)
                elseif (-not $isRunning -and -not $ps.Running) {
                    $downStr = '{0:hh\:mm\:ss}' -f ($now - $ps.DownSince)
                    Write-Log "$($proc.display_name) still NOT running (down $downStr)" Yellow
                    if ($proc.required) {
                        $vars = @{ timestamp = $now.ToString('yyyy-MM-dd HH:mm:ss'); hostname = $env:COMPUTERNAME; proc_name = $proc.name; proc_display = $proc.display_name }
                        Invoke-MonitorActions -Actions $proc.actions.on_not_running -Vars $vars -GlobalCfg $cfg -SuppressSpam:$true -AlertKey "process|$($proc.name)"
                        $ps.AlertCount++
                        $stateChanged = $true
                    }
                }
                # Transition: NOT running -> running (recovery)
                elseif ($isRunning -and -not $ps.Running) {
                    $downStr = '{0:hh\:mm\:ss}' -f ($now - $ps.DownSince)
                    $msg     = "[{0}] RECOVERY: {1} is running again (was down {2})." -f `
                               $now.ToString('yyyy-MM-dd HH:mm:ss'), $proc.name, $downStr
                    Write-Log "$($proc.display_name) is running again (was down $downStr)" Green
                    Write-MonitorLog $msg $cfg
                    $ps.Running    = $true
                    $ps.DownSince  = $null
                    $ps.AlertCount = 0
                    $stateChanged  = $true
                }
                # Still running -- silent
            }
            catch {
                Write-Log "Error checking $($proc.name): $_" Red
            }
        }

        if ($stateChanged) { Write-StateFile $processes $state }

        Start-Sleep -Seconds 1
    }
}
finally {
    Write-Log 'Process Monitor stopped.' DarkGray
}
