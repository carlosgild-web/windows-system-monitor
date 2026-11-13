#Requires -Version 5.1
$ErrorActionPreference = 'Continue'

# ── Settings ──────────────────────────────────────────────────────────────────
# Get-MonitorSettings: UTF-8 load + project-relative path resolution
. (Join-Path $PSScriptRoot 'lib\MonitorCommon.ps1')

# ── Template expansion ────────────────────────────────────────────────────────
function Expand-Template {
    param([string]$Template, [hashtable]$Vars, $Global)
    $result = $Template
    foreach ($kv in $Vars.GetEnumerator()) {
        $result = $result -replace "\{$($kv.Key)\}", $kv.Value
    }
    if ($Global) {
        $Global.PSObject.Properties | ForEach-Object {
            $result = $result -replace "\{global\.$($_.Name)\}", $_.Value
        }
    }
    return $result
}

# ── Actions ───────────────────────────────────────────────────────────────────
function Invoke-PopupAction {
    param($Action, [hashtable]$Vars, $Cfg)
    try {
        $title   = Expand-Template $Action.title            $Vars $Cfg.global
        $message = Expand-Template $Action.message_template $Vars $Cfg.global
        Show-MonitorPopup $title $message
    } catch {}
}

function Invoke-LogAction {
    param($Action, [hashtable]$Vars, $Cfg)
    $msg     = Expand-Template $Action.message_template $Vars $Cfg.global
    $logFile = $Cfg.global.log_file
    try {
        $dir = Split-Path $logFile
        if ($dir -and -not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
        $maxMb = [double]($Cfg.global.log_max_size_mb)
        if ((Test-Path $logFile) -and ((Get-Item $logFile).Length / 1MB) -ge $maxMb) {
            $archive = Join-Path $dir ((Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')
            Move-Item $logFile $archive -Force
        }
        Add-Content -Path $logFile -Value $msg -Encoding UTF8
    } catch {}
}

function Invoke-EmailAction {
    param($Action, [hashtable]$Vars, $Cfg)
    try {
        $to      = Expand-Template $Action.to               $Vars $Cfg.global
        $subject = Expand-Template $Action.subject_template  $Vars $Cfg.global
        $body    = Expand-Template $Action.body_template     $Vars $Cfg.global
        $uri = "mailto:$to`?subject=$([uri]::EscapeDataString($subject))&body=$([uri]::EscapeDataString($body))"
        Start-Process $uri
    } catch {}
}

function Invoke-ScriptAction {
    param($Action, [hashtable]$Vars, $Cfg)
    try {
        $path = Expand-Template $Action.path $Vars $Cfg.global
        if (-not (Test-Path $path)) { return }
        $argList = $Action.args | ForEach-Object { Expand-Template $_ $Vars $Cfg.global }
        & $path @argList
    } catch {}
}

function Invoke-Actions {
    param($Actions, [bool]$SuppressSpam, [hashtable]$Vars, $Cfg)
    foreach ($action in $Actions) {
        # Repeat alerts only re-run log_to_file and run_script (spam guard).
        if ($SuppressSpam -and $action.type -in @('popup', 'email_draft')) { continue }
        switch ($action.type) {
            'popup'       { Invoke-PopupAction $action $Vars $Cfg }
            'log_to_file' { Invoke-LogAction   $action $Vars $Cfg }
            'email_draft' { Invoke-EmailAction  $action $Vars $Cfg }
            'run_script'  { Invoke-ScriptAction $action $Vars $Cfg }
        }
    }
}

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
                    Invoke-Actions $t.actions $suppress $templateVars $cfg
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
