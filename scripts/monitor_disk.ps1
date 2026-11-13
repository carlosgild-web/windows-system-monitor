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
    $perLevelCounts = @{}
    foreach ($t in $d.thresholds) { $perLevelCounts[$t.level] = 0 }
    $state[$d.drive] = @{
        LastChecked  = $null
        AlertCounts  = $perLevelCounts
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

        # Sorted: warning before critical so critical wins as highestExceededLevel
        $sorted = @($d.thresholds | Sort-Object { if ($_.level -eq 'warning') { 0 } else { 1 } })

        $highestExceededLevel = $null
        foreach ($t in $sorted) {
            if ($null -ne $t.percent_used -and $info.PercentUsed -ge $t.percent_used) {
                $highestExceededLevel = $t.level
            }
        }

        foreach ($t in $sorted) {
            $lvl = $t.level
            if ($null -ne $t.percent_used -and $info.PercentUsed -ge $t.percent_used) {
                if ($lvl -eq $highestExceededLevel) {
                    $templateVars = @{
                        timestamp     = $now.ToString('yyyy-MM-dd HH:mm:ss')
                        hostname      = $hostname
                        current_value = [string]$info.PercentUsed
                        percent_used  = [string]$t.percent_used
                        free_gb       = [string]$info.FreeGB
                    }
                    $suppress = ($ds.AlertCounts[$lvl] -gt 0)
                    Invoke-Actions $t.actions $suppress $templateVars $cfg
                    $ds.AlertCounts[$lvl]++
                }
            } else {
                $ds.AlertCounts[$lvl] = 0
            }
        }

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
