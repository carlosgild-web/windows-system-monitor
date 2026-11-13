#Requires -Version 5.1
$ErrorActionPreference = 'Continue'

# ── Settings ──────────────────────────────────────────────────────────────────
# Get-MonitorSettings: UTF-8 load + project-relative path resolution
. (Join-Path $PSScriptRoot 'lib\MonitorCommon.ps1')
# Expand-Template / Invoke-MonitorActions: the shared alert actions
. (Join-Path $PSScriptRoot 'lib\MonitorActions.ps1')

# ── State file ────────────────────────────────────────────────────────────────
function Write-PerfStateFile {
    param($Cfg, $State, $MetricDefs)
    $stateFile = Join-Path (Split-Path $Cfg.global.log_file) 'performance_state.json'
    $metrics = @(
        foreach ($m in $MetricDefs) {
            $ms = $State[$m.Name]
            [ordered]@{
                name          = $m.Name
                display_name  = $m.DisplayName
                current_value = $ms.LastValue
                current_level = $ms.LastLevel
                last_check    = $ms.LastCheckStr
            }
        }
    )
    $payload = [ordered]@{
        updated     = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        monitor_pid = $PID
        metrics     = $metrics
    }
    try { $payload | ConvertTo-Json -Depth 5 | Set-Content $stateFile -Encoding UTF8 } catch {}
}

# ── Measurements ──────────────────────────────────────────────────────────────
function Get-CpuPercent {
    try {
        $s = (Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction Stop).CounterSamples[0].CookedValue
        return [math]::Round($s, 1)
    } catch { return $null }
}

function Get-MemPercent {
    try {
        $os   = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $used = $os.TotalVisibleMemorySize - $os.FreePhysicalMemory
        return [math]::Round($used / $os.TotalVisibleMemorySize * 100, 1)
    } catch { return $null }
}

# Returns the highest threshold level exceeded by $Value (immediate, no sustain gate)
function Get-ImmediateLevel {
    param([double]$Value, $Thresholds)
    $level = 'ok'
    foreach ($t in $Thresholds) {
        if ($null -ne $t.percent -and $Value -ge $t.percent) { $level = $t.level }
    }
    return $level
}

# ── Init ──────────────────────────────────────────────────────────────────────
$cfg = Get-MonitorSettings

$metricDefs = @(
    @{ Name = 'cpu';    DisplayName = 'CPU';          Config = $cfg.performance.cpu    }
    @{ Name = 'memory'; DisplayName = 'Memory (RAM)'; Config = $cfg.performance.memory }
)

$state = @{}
foreach ($m in $metricDefs) {
    $perLevel = @{}
    $perLevelCounts = @{}
    foreach ($t in $m.Config.thresholds) {
        $perLevel[$t.level]       = $null
        $perLevelCounts[$t.level] = 0
    }
    $state[$m.Name] = @{
        LastChecked         = $null
        AboveThresholdSince = $perLevel
        AlertCounts         = $perLevelCounts
        LastValue           = $null
        LastLevel           = 'ok'
        LastCheckStr        = $null
    }
}

$hostname = $env:COMPUTERNAME

# ── Main loop ─────────────────────────────────────────────────────────────────
while ($true) {
    $now          = Get-Date
    $stateChanged = $false

    foreach ($m in $metricDefs) {
        $ms   = $state[$m.Name]
        $mcfg = $m.Config

        if ($ms.LastChecked -and ($now - $ms.LastChecked).TotalSeconds -lt $mcfg.check_interval_sec) {
            continue
        }
        $ms.LastChecked  = $now
        $ms.LastCheckStr = $now.ToString('yyyy-MM-dd HH:mm:ss')
        $stateChanged    = $true

        $value = if ($m.Name -eq 'cpu') { Get-CpuPercent } else { Get-MemPercent }
        if ($null -eq $value) { continue }

        $ms.LastValue = $value
        $ms.LastLevel = Get-ImmediateLevel -Value $value -Thresholds $mcfg.thresholds

        # Thresholds sorted warning-first so critical is last (and wins as highestExceeded)
        $sorted = @($mcfg.thresholds | Sort-Object { if ($_.level -eq 'warning') { 0 } else { 1 } })

        $highestExceededLevel = $null
        foreach ($t in $sorted) {
            if ($null -ne $t.percent -and $value -ge $t.percent) { $highestExceededLevel = $t.level }
        }

        foreach ($t in $sorted) {
            $lvl = $t.level
            if ($null -ne $t.percent -and $value -ge $t.percent) {
                if ($null -eq $ms.AboveThresholdSince[$lvl]) {
                    $ms.AboveThresholdSince[$lvl] = $now
                }
                $sustainedSec = ($now - $ms.AboveThresholdSince[$lvl]).TotalSeconds
                # Only fire the highest exceeded threshold to avoid duplicate alerts
                if ($sustainedSec -ge $t.sustain_sec -and $lvl -eq $highestExceededLevel) {
                    $templateVars = @{
                        timestamp     = $now.ToString('yyyy-MM-dd HH:mm:ss')
                        hostname      = $hostname
                        current_value = [string][math]::Round($value, 1)
                        percent       = [string]$t.percent
                        sustain_sec   = [string]$t.sustain_sec
                    }
                    $suppress = ($ms.AlertCounts[$lvl] -gt 0)
                    Invoke-MonitorActions -Actions $t.actions -Vars $templateVars -GlobalCfg $cfg.global -SuppressSpam:$suppress
                    $ms.AlertCounts[$lvl]++
                }
            } else {
                $ms.AboveThresholdSince[$lvl] = $null
                $ms.AlertCounts[$lvl]         = 0
            }
        }
    }

    if ($stateChanged) {
        Write-PerfStateFile -Cfg $cfg -State $state -MetricDefs $metricDefs
    }

    Start-Sleep -Seconds 1
}
