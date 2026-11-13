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
function Write-NetStateFile {
    param($Cfg, $Hosts)
    $stateFile = Join-Path (Split-Path $Cfg.global.log_file) 'network_state.json'
    $payload = [ordered]@{
        updated     = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        monitor_pid = $PID
        hosts       = $Hosts
    }
    try { $payload | ConvertTo-Json -Depth 5 | Set-Content $stateFile -Encoding UTF8 } catch {}
}

# ── Connectivity checks ───────────────────────────────────────────────────────
function Measure-Icmp {
    param([string]$Target, [int]$TimeoutMs)
    try {
        $ping  = New-Object System.Net.NetworkInformation.Ping
        $reply = $ping.Send($Target, $TimeoutMs)
        if ($reply.Status -eq 'Success') {
            return @{ Reachable = $true; LatencyMs = [int]$reply.RoundtripTime }
        }
        return @{ Reachable = $false; LatencyMs = $null }
    } catch {
        return @{ Reachable = $false; LatencyMs = $null }
    }
}

function Measure-Tcp {
    param([string]$Target, [int]$Port, [int]$TimeoutSec)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $task   = $client.ConnectAsync($Target, $Port)
        $done   = $task.Wait([TimeSpan]::FromSeconds($TimeoutSec))
        $elapsed = [int]$sw.ElapsedMilliseconds
        $client.Dispose()
        if ($done -and -not $task.IsFaulted) {
            return @{ Reachable = $true; LatencyMs = $elapsed }
        }
        return @{ Reachable = $false; LatencyMs = $null }
    } catch {
        return @{ Reachable = $false; LatencyMs = $null }
    }
}

# ── Init ──────────────────────────────────────────────────────────────────────
$cfg = Get-MonitorSettings

$state = @{}
foreach ($h in $cfg.network) {
    $perLevelCounts = @{}
    foreach ($t in $h.thresholds) { $perLevelCounts[$t.level] = 0 }
    $state[$h.name] = @{
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
    $hostsOutput  = [System.Collections.Generic.List[object]]::new()

    foreach ($h in $cfg.network) {
        $hs       = $state[$h.name]
        $interval = [int]($h.check_interval_sec)

        if ($hs.LastChecked -and ($now - $hs.LastChecked).TotalSeconds -lt $interval) {
            if ($hs.LastResult) {
                $hostsOutput.Add([ordered]@{
                    name          = $h.name
                    host          = $h.host
                    port          = $h.port
                    protocol      = $h.protocol
                    reachable     = $hs.LastResult.Reachable
                    latency_ms    = $hs.LastResult.LatencyMs
                    current_level = $hs.LastLevel
                    last_check    = $hs.LastCheckStr
                })
            }
            continue
        }

        $hs.LastChecked  = $now
        $hs.LastCheckStr = $now.ToString('yyyy-MM-dd HH:mm:ss')
        $stateChanged    = $true

        $timeoutSec = [int]($h.timeout_sec)
        $result = if ($h.protocol -eq 'tcp') {
            Measure-Tcp -Target $h.host -Port $h.port -TimeoutSec $timeoutSec
        } else {
            Measure-Icmp -Target $h.host -TimeoutMs ($timeoutSec * 1000)
        }

        $hs.LastResult = $result

        # Determine current level
        $currentLevel = 'ok'
        foreach ($t in $h.thresholds) {
            if ($t.condition -eq 'unreachable' -and -not $result.Reachable) {
                $currentLevel = $t.level
            } elseif ($null -ne $t.latency_ms -and $result.Reachable -and $null -ne $result.LatencyMs -and $result.LatencyMs -ge $t.latency_ms) {
                $currentLevel = $t.level
            }
        }
        $hs.LastLevel = $currentLevel

        # Fire actions per threshold, highest applicable only
        $sorted = @($h.thresholds | Sort-Object { if ($_.level -eq 'warning') { 0 } else { 1 } })

        $highestExceededLevel = $null
        foreach ($t in $sorted) {
            if ($t.condition -eq 'unreachable' -and -not $result.Reachable) {
                $highestExceededLevel = $t.level
            } elseif ($null -ne $t.latency_ms -and $result.Reachable -and $null -ne $result.LatencyMs -and $result.LatencyMs -ge $t.latency_ms) {
                $highestExceededLevel = $t.level
            }
        }

        foreach ($t in $sorted) {
            $lvl      = $t.level
            $exceeded = ($t.condition -eq 'unreachable' -and -not $result.Reachable) -or
                        ($null -ne $t.latency_ms -and $result.Reachable -and $null -ne $result.LatencyMs -and $result.LatencyMs -ge $t.latency_ms)

            if ($exceeded -and $lvl -eq $highestExceededLevel) {
                $templateVars = @{
                    timestamp     = $now.ToString('yyyy-MM-dd HH:mm:ss')
                    hostname      = $hostname
                    host          = [string]$h.host
                    port          = [string]$h.port
                    current_value = if ($null -ne $result.LatencyMs) { [string]$result.LatencyMs } else { 'unreachable' }
                    # The threshold, like {percent} and {percent_used} in the other
                    # monitors; the measured value is {current_value}.
                    latency_ms    = if ($null -ne $t.latency_ms) { [string]$t.latency_ms } else { 'N/A' }
                }
                $suppress = ($hs.AlertCounts[$lvl] -gt 0)
                Invoke-Actions $t.actions $suppress $templateVars $cfg
                $hs.AlertCounts[$lvl]++
            } elseif (-not $exceeded) {
                $hs.AlertCounts[$lvl] = 0
            }
        }

        $hostsOutput.Add([ordered]@{
            name          = $h.name
            host          = $h.host
            port          = $h.port
            protocol      = $h.protocol
            reachable     = $result.Reachable
            latency_ms    = $result.LatencyMs
            current_level = $hs.LastLevel
            last_check    = $hs.LastCheckStr
        })
    }

    if ($stateChanged -and $hostsOutput.Count -gt 0) {
        Write-NetStateFile -Cfg $cfg -Hosts $hostsOutput
    }

    Start-Sleep -Seconds 1
}
