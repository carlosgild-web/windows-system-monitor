#Requires -Version 5.1
<#
.SYNOPSIS
    Document Monitor -- watches one number in a CSV or Excel file (the "document" section).
.DESCRIPTION
    Every check_interval_sec it sums value_column over the rows where filter_column equals
    filter_value, compares the total with target, and fires the thresholds' actions when the
    total goes above (or below) a percent of the target. The same hysteresis, spam guard and
    email cooldown as the other monitors apply. Writes logs\document_state.json every cycle.

    Settings are re-read on every cycle, so editing the target or the file path takes effect
    without a restart.
#>
$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'lib\MonitorCommon.ps1')    # Get-MonitorSettings, Resolve-ProjectPath
. (Join-Path $PSScriptRoot 'lib\MonitorActions.ps1')   # Invoke-ThresholdAlerts and the actions
. (Join-Path $PSScriptRoot 'lib\DocumentReader.ps1')   # Get-DocumentTotal

$trackers  = @{}                  # level -> incident tracker, kept across cycles
$hostname  = $env:COMPUTERNAME

function Write-DocumentStateFile ($Cfg, $State) {
    $stateFile = Join-Path (Split-Path $Cfg.global.log_file) 'document_state.json'
    try {
        $dir = Split-Path $stateFile -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $State | ConvertTo-Json -Depth 4 | Set-Content -Path $stateFile -Encoding UTF8
    } catch {}
}

while ($true) {
    $checkSec = 60
    try {
        $cfg = Get-MonitorSettings
        $doc = $cfg.document
        $now = Get-Date
        if ($null -ne $doc -and $doc.check_interval_sec -gt 0) { $checkSec = [int]$doc.check_interval_sec }

        $state = [ordered]@{
            updated           = $now.ToString('yyyy-MM-dd HH:mm:ss')
            monitor_pid       = $PID
            display_name      = if ($doc) { [string]$doc.display_name } else { 'Document' }
            path              = if ($doc) { [string]$doc.path } else { $null }
            total             = $null
            target            = $null
            unit              = if ($doc -and $null -ne $doc.unit) { [string]$doc.unit } else { '' }
            percent_of_target = $null
            current_level     = 'unknown'
            error             = $null
        }

        if ($null -eq $doc) {
            $state.error = 'No "document" section in monitoring_settings.json'
        } else {
            $result = Get-DocumentTotal $doc
            $target = [double]$doc.target
            $state.target = $target
            $state.error  = $result.error
            if ($null -ne $result.total) {
                $total = [double]$result.total
                $eval  = Get-DocumentChecks -Doc $doc -Total $total -Now $now -Hostname $hostname
                $state.total             = $total
                $state.percent_of_target = $eval.Percent
                $state.current_level     = $eval.Level
                if ($eval.Checks.Count -gt 0) {
                    $null = Invoke-ThresholdAlerts -Checks $eval.Checks -Trackers $trackers -Now $now `
                        -GlobalCfg $cfg.global -KeyPrefix "document|$($state.display_name)"
                }
            }
        }
        Write-DocumentStateFile $cfg $state
    }
    catch {
        # keep the loop alive; the next cycle retries
    }
    Start-Sleep -Seconds $checkSec
}
