#Requires -Version 5.1
<#
.SYNOPSIS
    The four alert actions, shared by every monitor (dot-sourced after MonitorCommon.ps1).
.DESCRIPTION
    - Expand-Template       : fills {var} and {global.<field>} placeholders.
    - Write-MonitorLog      : appends one line to global.log_file, rotating it at log_max_size_mb.
    - Invoke-MonitorActions : runs a threshold's action list (popup, log_to_file, email_draft,
                              run_script). With -SuppressSpam (a repeat alert) only log_to_file
                              and run_script run.

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

function Invoke-MonitorActions {
    param($Actions, [hashtable]$Vars, $GlobalCfg, [switch]$SuppressSpam)
    foreach ($action in @($Actions)) {
        if ($null -eq $action) { continue }
        # Spam guard: repeat alerts only re-run log_to_file and run_script.
        if ($SuppressSpam -and $action.type -in @('popup', 'email_draft')) { continue }
        try {
            switch ($action.type) {
                'popup'       { Invoke-PopupAction  $action $Vars $GlobalCfg }
                'log_to_file' { Invoke-LogAction    $action $Vars $GlobalCfg }
                'email_draft' { Invoke-EmailAction  $action $Vars $GlobalCfg }
                'run_script'  { Invoke-ScriptAction $action $Vars $GlobalCfg }
                default       { Write-ActionTrace "Unknown action type: $($action.type)" Yellow }
            }
        }
        catch { Write-ActionTrace "Action '$($action.type)' failed: $_" Red }
    }
}
