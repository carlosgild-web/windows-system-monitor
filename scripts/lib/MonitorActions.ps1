#Requires -Version 5.1
<#
.SYNOPSIS
    The four alert actions, shared by every monitor (dot-sourced after MonitorCommon.ps1).
.DESCRIPTION
    - Expand-Template       : fills {var} and {global.<field>} placeholders.
    - Write-MonitorLog      : appends one line to global.log_file, rotating it at log_max_size_mb.
    - Invoke-MonitorActions : runs a threshold's action list (popup, log_to_file, email_draft,
                              run_script). With -SuppressSpam (a repeat alert) only log_to_file
                              and run_script run. With -AlertKey, email_draft is limited to one
                              per key per global.email_cooldown_min (saved in logs\alert_state.json,
                              so restarts don't reset it).
    - Invoke-ThresholdAlerts: one check of a threshold list with hysteresis. An incident opens
                              after sustain_sec above the threshold and closes only after the value
                              stays below (threshold - clear margin) for clear_sec, so a value
                              hovering around the threshold is one incident, not many. Only the
                              highest open or exceeded level acts.

    A monitor that shows a console window can set $MonitorActionTrace = $true after
    dot-sourcing to print one line per action; hidden monitors leave it off.
#>

function Write-ActionTrace ([string]$Message, [ConsoleColor]$Color = 'DarkGray') {
    if ($MonitorActionTrace) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')]   $Message" -ForegroundColor $Color
    }
}

function Expand-Template ([string]$Text, [hashtable]$Vars, $GlobalCfg) {
    # Placeholders match case-insensitively (-replace). Values are inserted literally:
    # '$' is escaped so a value such as 'C$' or '$1' is never read as a regex group.
    if ($GlobalCfg) {
        foreach ($p in $GlobalCfg.PSObject.Properties) {
            $Text = $Text -replace [regex]::Escape("{global.$($p.Name)}"), ([string]$p.Value).Replace('$', '$$')
        }
    }
    if ($Vars) {
        foreach ($k in $Vars.Keys) {
            $Text = $Text -replace [regex]::Escape("{$k}"), ([string]$Vars[$k]).Replace('$', '$$')
        }
    }
    return $Text
}

function Write-MonitorLog ([string]$Message, $GlobalCfg) {
    $logPath = [string]$GlobalCfg.log_file
    if (-not $logPath) { return }
    $logDir = Split-Path $logPath -Parent
    if ($logDir -and -not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $maxMb = [double]$GlobalCfg.log_max_size_mb
    if ($maxMb -gt 0 -and (Test-Path $logPath) -and (Get-Item $logPath).Length -ge ($maxMb * 1MB)) {
        # logs\monitor.log -> logs\monitor.20261113_101500.log
        $archive = [System.IO.Path]::ChangeExtension($logPath, "$(Get-Date -Format 'yyyyMMdd_HHmmss').log")
        Move-Item -Path $logPath -Destination $archive -Force
    }
    Add-Content -Path $logPath -Value $Message -Encoding UTF8
}

function Invoke-PopupAction ($Action, [hashtable]$Vars, $GlobalCfg) {
    # Process actions carry their text in 'instructions'; every other section uses 'message_template'.
    $text    = if ($Action.PSObject.Properties['message_template']) { $Action.message_template } else { $Action.instructions }
    $title   = Expand-Template $Action.title $Vars $GlobalCfg
    $message = Expand-Template $text         $Vars $GlobalCfg
    Show-MonitorPopup $title $message
    Write-ActionTrace "[popup] $title" Yellow
}

function Invoke-LogAction ($Action, [hashtable]$Vars, $GlobalCfg) {
    if ($Action.PSObject.Properties['instructions']) {
        # 'instructions' is a runbook for the console, never logged. Write a compact line instead.
        $message = '[{0}] {1} PROC: {2} ({3}) not detected.' -f $Vars['timestamp'], ([string]$Action.level).ToUpper(),
                   $Vars['proc_display'], $Vars['proc_name']
    } else {
        $message = Expand-Template $Action.message_template $Vars $GlobalCfg
    }
    Write-MonitorLog $message $GlobalCfg
    Write-ActionTrace "[log] $message"
}

function Invoke-EmailAction ($Action, [hashtable]$Vars, $GlobalCfg) {
    $to      = Expand-Template $Action.to               $Vars $GlobalCfg
    $subject = Expand-Template $Action.subject_template $Vars $GlobalCfg
    $body    = Expand-Template $Action.body_template    $Vars $GlobalCfg
    # Escape the recipient too (a stray '?' or '&' must not start new mailto fields),
    # but keep '@' and ',' readable for mail clients.
    $recipient = [Uri]::EscapeDataString($to) -replace '%40', '@' -replace '%2C', ','
    $mailto    = 'mailto:' + $recipient +
                 '?subject=' + [Uri]::EscapeDataString($subject) +
                 '&body='    + [Uri]::EscapeDataString($body)
    Start-Process $mailto
    Write-ActionTrace "[email_draft] to $to" Cyan
}

function Invoke-ScriptAction ($Action, [hashtable]$Vars, $GlobalCfg) {
    $path = Expand-Template $Action.path $Vars $GlobalCfg
    if (-not (Test-Path $path)) { Write-ActionTrace "[run_script] not found: $path" Red; return }
    $argList = @($Action.args | ForEach-Object { Expand-Template $_ $Vars $GlobalCfg })
    & $path @argList
    Write-ActionTrace "[run_script] $path"
}

# ---- Email cooldown -------------------------------------------------------------
function Get-EmailCooldownMinutes ($GlobalCfg) {
    if ($GlobalCfg -and $GlobalCfg.PSObject.Properties['email_cooldown_min'] -and $null -ne $GlobalCfg.email_cooldown_min) {
        return [double]$GlobalCfg.email_cooldown_min
    }
    return 60
}

function Request-EmailSlot ([string]$Key, $GlobalCfg, [datetime]$Now = (Get-Date)) {
    # True (and the time is recorded) when no email for $Key was opened within the cooldown.
    # Every monitor process shares logs\alert_state.json, so the read-check-write runs under
    # a named mutex. If anything goes wrong the email is allowed: a duplicate draft is
    # better than a missed alert.
    $minutes = Get-EmailCooldownMinutes $GlobalCfg
    if ($minutes -le 0) { return $true }
    $path = Join-Path (Split-Path ([string]$GlobalCfg.log_file) -Parent) 'alert_state.json'
    $mutex = New-Object System.Threading.Mutex($false, 'Local\WindowsSystemMonitor.AlertState')
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(3000) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
        $sent = @{}
        if (Test-Path $path) {
            $saved = (Get-Content $path -Raw -Encoding UTF8) | ConvertFrom-Json
            if ($saved -and $saved.email_sent) {
                foreach ($p in $saved.email_sent.PSObject.Properties) { $sent[$p.Name] = $p.Value }
            }
        }
        if ($sent.ContainsKey($Key)) {
            $last = $sent[$Key]
            if ($last -isnot [datetime]) {
                $last = [datetime]::ParseExact([string]$last, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
            }
            if (($Now - $last).TotalMinutes -lt $minutes) { return $false }
        }
        $sent[$Key] = $Now.ToString('yyyy-MM-dd HH:mm:ss')
        $dir = Split-Path $path -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [ordered]@{ email_sent = $sent } | ConvertTo-Json -Depth 3 | Set-Content -Path $path -Encoding UTF8
        return $true
    }
    catch {
        Write-ActionTrace "alert_state.json unusable, email allowed: $_" Yellow
        return $true
    }
    finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Invoke-MonitorActions {
    param($Actions, [hashtable]$Vars, $GlobalCfg, [switch]$SuppressSpam, [string]$AlertKey)
    foreach ($action in @($Actions)) {
        if ($null -eq $action) { continue }
        # Spam guard: repeat alerts only re-run log_to_file and run_script.
        if ($SuppressSpam -and $action.type -in @('popup', 'email_draft')) { continue }
        try {
            switch ($action.type) {
                'popup'       { Invoke-PopupAction  $action $Vars $GlobalCfg }
                'log_to_file' { Invoke-LogAction    $action $Vars $GlobalCfg }
                'email_draft' {
                    if (-not $AlertKey -or (Request-EmailSlot $AlertKey $GlobalCfg)) {
                        Invoke-EmailAction $action $Vars $GlobalCfg
                    } else {
                        $msg = '[{0}] INFO email_draft for {1} skipped: one was opened less than {2} min ago (global.email_cooldown_min)' -f
                               (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $AlertKey, (Get-EmailCooldownMinutes $GlobalCfg)
                        Write-MonitorLog $msg $GlobalCfg
                        Write-ActionTrace "[email_draft] skipped (cooldown): $AlertKey" DarkYellow
                    }
                }
                'run_script'  { Invoke-ScriptAction $action $Vars $GlobalCfg }
                default       { Write-ActionTrace "Unknown action type: $($action.type)" Yellow }
            }
        }
        catch { Write-ActionTrace "Action '$($action.type)' failed: $_" Red }
    }
}

# ---- Incidents with hysteresis ----------------------------------------------------
function New-AlertTracker {
    return @{ AboveSince = $null; ClearSince = $null; Active = $false; AlertCount = 0 }
}

function Step-AlertTracker {
    # Advances one level's incident by one check. Returns 'first' (open the incident: run
    # every action), 'repeat' (still open: log/script only) or 'none'.
    param([hashtable]$Tracker, [bool]$Exceeded, [bool]$BelowClear, [datetime]$Now,
          [double]$SustainSec = 0, [double]$ClearSec = 0)
    if ($Exceeded) {
        $Tracker.ClearSince = $null
        if ($Tracker.Active) { return 'repeat' }
        if ($null -eq $Tracker.AboveSince) { $Tracker.AboveSince = $Now }
        if (($Now - $Tracker.AboveSince).TotalSeconds -ge $SustainSec) { return 'first' }
        return 'none'
    }
    $Tracker.AboveSince = $null
    if ($Tracker.Active) {
        if ($BelowClear) {
            if ($null -eq $Tracker.ClearSince) { $Tracker.ClearSince = $Now }
            if (($Now - $Tracker.ClearSince).TotalSeconds -ge $ClearSec) {
                $Tracker.Active     = $false
                $Tracker.ClearSince = $null
                $Tracker.AlertCount = 0
            }
        } else {
            # Between the clear point and the threshold: the incident stays open.
            $Tracker.ClearSince = $null
        }
    }
    return 'none'
}

function Invoke-ThresholdAlerts {
    # $Checks: one entry per threshold, lowest level first, each a hashtable with
    #   Level, Actions, Exceeded, BelowClear, SustainSec, ClearSec, Vars.
    # $Trackers: the item's persistent level -> tracker table (created on first use).
    # Returns the level that is currently open or exceeded (or $null).
    param([object[]]$Checks, [hashtable]$Trackers, [datetime]$Now, $GlobalCfg, [string]$KeyPrefix)
    $decision = @{}
    foreach ($c in $Checks) {
        if (-not $Trackers.ContainsKey($c.Level)) { $Trackers[$c.Level] = New-AlertTracker }
        $decision[$c.Level] = Step-AlertTracker -Tracker $Trackers[$c.Level] -Exceeded ([bool]$c.Exceeded) `
            -BelowClear ([bool]$c.BelowClear) -Now $Now -SustainSec ([double]$c.SustainSec) -ClearSec ([double]$c.ClearSec)
    }
    # A lower level never fires while a higher one is exceeded or still open.
    $top = $null
    foreach ($c in $Checks) {
        if ($c.Exceeded -or $Trackers[$c.Level].Active) { $top = $c.Level }
    }
    foreach ($c in $Checks) {
        if ($c.Level -ne $top -or $decision[$c.Level] -eq 'none') { continue }
        Invoke-MonitorActions -Actions $c.Actions -Vars $c.Vars -GlobalCfg $GlobalCfg `
            -SuppressSpam:($decision[$c.Level] -eq 'repeat') -AlertKey "$KeyPrefix|$($c.Level)"
        $Trackers[$c.Level].Active = $true
        $Trackers[$c.Level].AlertCount++
    }
    return $top
}

function Get-ThresholdsLowFirst ($Thresholds) {
    # warning before critical, so the highest level is last
    return @(@($Thresholds) | Where-Object { $null -ne $_ } |
        Sort-Object { if ($_.level -eq 'warning') { 0 } else { 1 } })
}

function Get-ClearSetting ($Threshold, [string]$Name, [double]$Default) {
    # Optional per-threshold override (clear_margin, clear_sec), else the monitor's default.
    if ($Threshold.PSObject.Properties[$Name] -and $null -ne $Threshold.$Name) { return [double]$Threshold.$Name }
    return $Default
}
