#Requires -Version 5.1
<#
.SYNOPSIS
    Shared helper for the sample run_script handlers in scripts\actions\.
.DESCRIPTION
    Monitors call handlers in-process (& $path @args) with GNU-style
    arguments taken from monitoring_settings.json, e.g.
        on_cpu_critical.ps1 --level critical --value 97.3
    ConvertFrom-HandlerArgs turns that list into a hashtable, and
    Write-HandlerLog records the call in the shared monitor log so the
    run_script action is visible end-to-end.

    Handlers run synchronously inside the monitor loop: keep them fast, and
    start long-running work with Start-Process instead of running it inline.
#>

. (Join-Path $PSScriptRoot 'MonitorCommon.ps1')

function ConvertFrom-HandlerArgs ([object[]]$ArgList) {
    $map = @{}
    for ($i = 0; $i -lt $ArgList.Count; $i++) {
        $token = [string]$ArgList[$i]
        if ($token.StartsWith('--')) {
            $key   = $token.Substring(2)
            $value = $true
            if ($i + 1 -lt $ArgList.Count -and -not ([string]$ArgList[$i + 1]).StartsWith('--')) {
                $value = $ArgList[$i + 1]
                $i++
            }
            $map[$key] = $value
        }
    }
    return $map
}

function Write-HandlerLog ([string]$Handler, [string]$Message) {
    try {
        $cfg     = Get-MonitorSettings
        $logFile = $cfg.global.log_file
        $dir     = Split-Path $logFile -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
        $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -Path $logFile -Value "[$ts] ACTION $($Handler): $Message" -Encoding UTF8
    } catch {
        # Never let a handler failure break the calling monitor loop.
    }
}
