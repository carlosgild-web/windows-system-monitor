#Requires -Version 5.1
$ErrorActionPreference = 'Continue'

# ── Settings ──────────────────────────────────────────────────────────────────
# Get-MonitorSettings: UTF-8 load + project-relative path resolution
. (Join-Path $PSScriptRoot 'lib\MonitorCommon.ps1')
# Expand-Template / Invoke-MonitorActions: the shared alert actions
. (Join-Path $PSScriptRoot 'lib\MonitorActions.ps1')

# ── State file ────────────────────────────────────────────────────────────────
function Write-DiskStateFile {
    param($Cfg, $Drives)
    $stateFile = Join-Path (Split-Path $Cfg.global.log_file) 'disk_state.json'
    $payload = [ordered]@{
        updated     = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        monitor_pid = $PID
        drives      = $Drives
    }
    try { $payload | ConvertTo-Json -Depth 5 | Set-Content $stateFile -Encoding UTF8 } catch {}
}

# ── Measure disk ──────────────────────────────────────────────────────────────
function Get-DiskInfo {
    param([string]$Drive)
    try {
        $deviceId = $Drive.TrimEnd('\')
        $ld = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$deviceId'" -ErrorAction Stop
        if (-not $ld -or $ld.Size -eq 0) { return $null }
        $freeGB      = [math]::Round($ld.FreeSpace / 1GB, 1)
        $percentUsed = [math]::Round(($ld.Size - $ld.FreeSpace) / $ld.Size * 100, 1)
        return @{ PercentUsed = $percentUsed; FreeGB = $freeGB }
    } catch { return $null }
}

# Returns the highest threshold level currently exceeded by $PercentUsed
function Get-ImmediateLevel {
    param([double]$PercentUsed, $Thresholds)
    $level = 'ok'
    foreach ($t in $Thresholds) {
        if ($null -ne $t.percent_used -and $PercentUsed -ge $t.percent_used) { $level = $t.level }
    }
    return $level
}

# ── Init ──────────────────────────────────────────────────────────────────────
$cfg = Get-MonitorSettings

$state = @{}
foreach ($d in $cfg.disk) {
    $state[$d.drive] = @{
        LastChecked  = $null
        Trackers     = @{}      # level -> incident tracker (see Invoke-ThresholdAlerts)
        LastResult   = $null
        LastLevel    = 'ok'
        LastCheckStr = $null
    }
}

$hostname = $env:COMPUTERNAME

# ── Main loop ─────────────────────────────────────────────────────────────────
while ($true) {
    $now          = Get-Date
    $stateChanged = $false
    $drivesOutput = [System.Collections.Generic.List[object]]::new()

    foreach ($d in $cfg.disk) {
        $ds   = $state[$d.drive]
        $interval = [int]($d.check_interval_sec)

        if ($ds.LastChecked -and ($now - $ds.LastChecked).TotalSeconds -lt $interval) {
            # Not time to check yet — emit cached row
            if ($ds.LastResult) {
                $drivesOutput.Add([ordered]@{
                    drive         = $d.drive
                    display_name  = $d.display_name
                    percent_used  = $ds.LastResult.PercentUsed
                    free_gb       = $ds.LastResult.FreeGB
                    current_level = $ds.LastLevel
                    last_check    = $ds.LastCheckStr
                })
            }
            continue
        }

        $ds.LastChecked  = $now
        $ds.LastCheckStr = $now.ToString('yyyy-MM-dd HH:mm:ss')
        $stateChanged    = $true

        $info = Get-DiskInfo -Drive $d.drive
        if ($null -eq $info) {
            $drivesOutput.Add([ordered]@{
                drive         = $d.drive
                display_name  = $d.display_name
                percent_used  = $null
                free_gb       = $null
                current_level = 'unknown'
                last_check    = $ds.LastCheckStr
            })
            continue
        }

        $ds.LastResult = $info
        $ds.LastLevel  = Get-ImmediateLevel -PercentUsed $info.PercentUsed -Thresholds $d.thresholds

        # Hysteresis: an incident closes only after usage stays clear_margin points under the
        # threshold (default 2) for clear_sec (default: one check interval, i.e. two good checks).
        $checks = foreach ($t in (Get-ThresholdsLowFirst $d.thresholds)) {
            if ($null -eq $t.percent_used) { continue }
            @{
                Level      = $t.level
                Actions    = $t.actions
                Exceeded   = ($info.PercentUsed -ge $t.percent_used)
                BelowClear = ($info.PercentUsed -lt ($t.percent_used - (Get-ClearSetting $t 'clear_margin' 2)))
                SustainSec = 0
                ClearSec   = (Get-ClearSetting $t 'clear_sec' $interval)
                Vars       = @{
                    timestamp     = $now.ToString('yyyy-MM-dd HH:mm:ss')
                    hostname      = $hostname
                    current_value = [string]$info.PercentUsed
                    percent_used  = [string]$t.percent_used
                    free_gb       = [string]$info.FreeGB
                }
            }
        }
        $null = Invoke-ThresholdAlerts -Checks @($checks) -Trackers $ds.Trackers -Now $now `
            -GlobalCfg $cfg.global -KeyPrefix "disk|$($d.drive)"

        $drivesOutput.Add([ordered]@{
            drive         = $d.drive
            display_name  = $d.display_name
            percent_used  = $info.PercentUsed
            free_gb       = $info.FreeGB
            current_level = $ds.LastLevel
            last_check    = $ds.LastCheckStr
        })
    }

    if ($stateChanged -and $drivesOutput.Count -gt 0) {
        Write-DiskStateFile -Cfg $cfg -Drives $drivesOutput
    }

    Start-Sleep -Seconds 1
}
