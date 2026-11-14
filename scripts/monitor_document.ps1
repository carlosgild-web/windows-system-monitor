#Requires -Version 5.1
<#
.SYNOPSIS
    Document Monitor -- watches one number per entry of the "document" list: a total in a
    CSV or Excel file, or a file's size.
.DESCRIPTION
    Each entry is checked every check_interval_sec. measure "sum" (the default) sums
    value_column over the rows where filter_column equals filter_value; measure "file_size"
    reads the file's size in size_unit. The value is compared with target, and the
    thresholds' actions fire when it goes above (or below) a percent of the target. The same
    hysteresis, spam guard and email cooldown as the other monitors apply. Writes
    logs\document_state.json whenever an entry is checked.

    Settings are re-read on every pass, so adding a document or editing a target or a file
    path takes effect without a restart.
#>
$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'lib\MonitorCommon.ps1')    # Get-MonitorSettings, Resolve-ProjectPath
. (Join-Path $PSScriptRoot 'lib\MonitorActions.ps1')   # Invoke-ThresholdAlerts and the actions
. (Join-Path $PSScriptRoot 'lib\DocumentReader.ps1')   # Get-DocumentList, Get-DocumentTotal, Get-DocumentChecks

$docState = @{}                   # display_name -> @{ LastChecked; Trackers; Row }, kept across passes
$hostname = $env:COMPUTERNAME

function Write-DocumentStateFile ($Cfg, $Rows) {
    $stateFile = Join-Path (Split-Path $Cfg.global.log_file) 'document_state.json'
    $payload = [ordered]@{
        updated     = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        monitor_pid = $PID
        documents   = @($Rows)
    }
    try {
        $dir = Split-Path $stateFile -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        ConvertTo-Json -InputObject $payload -Depth 5 | Set-Content -Path $stateFile -Encoding UTF8
    } catch {}
}

function Measure-Document ($Doc, [datetime]$Now, $Ds, $GlobalCfg) {
    $name = if ($Doc.display_name) { [string]$Doc.display_name } else { 'Document' }
    $row = [ordered]@{
        display_name      = $name
        path              = [string]$Doc.path
        measure           = Get-DocumentMeasure $Doc
        total             = $null
        target            = $null
        unit              = Get-DocumentUnit $Doc
        percent_of_target = $null
        current_level     = 'unknown'
        error             = $null
        note              = $null
        last_check        = $Now.ToString('yyyy-MM-dd HH:mm:ss')
    }
    $result = Get-DocumentTotal $Doc
    $row.target = [double]$Doc.target
    $row.error  = $result.error
    $row.note   = $result.note
    if ($null -ne $result.total) {
        $total = [double]$result.total
        $eval  = Get-DocumentChecks -Doc $Doc -Total $total -Now $Now -Hostname $hostname
        $row.total             = $total
        $row.percent_of_target = $eval.Percent
        $row.current_level     = $eval.Level
        if ($eval.Checks.Count -gt 0) {
            $null = Invoke-ThresholdAlerts -Checks $eval.Checks -Trackers $Ds.Trackers -Now $Now `
                -GlobalCfg $GlobalCfg -KeyPrefix "document|$name"
        }
    }
    return $row
}

while ($true) {
    try {
        $cfg     = Get-MonitorSettings
        $now     = Get-Date
        $changed = $false
        $rows    = [System.Collections.Generic.List[object]]::new()

        foreach ($doc in (Get-DocumentList $cfg)) {
            try {
                $name = if ($doc.display_name) { [string]$doc.display_name } else { 'Document' }
                if (-not $docState.ContainsKey($name)) {
                    $docState[$name] = @{ LastChecked = $null; Trackers = @{}; Row = $null }
                }
                $ds       = $docState[$name]
                $interval = if ($doc.check_interval_sec -gt 0) { [int]$doc.check_interval_sec } else { 60 }

                if ($ds.LastChecked -and ($now - $ds.LastChecked).TotalSeconds -lt $interval -and $ds.Row) {
                    $rows.Add($ds.Row)             # not due yet: keep the last result
                    continue
                }
                $ds.LastChecked = $now
                $ds.Row         = Measure-Document $doc $now $ds $cfg.global
                $rows.Add($ds.Row)
                $changed = $true
            }
            catch {
                # one bad entry must not stop the others
            }
        }

        # Forget documents that were removed from the settings, and write the file when
        # something was checked or the list changed.
        $names = @($rows | ForEach-Object { $_.display_name })
        foreach ($k in @($docState.Keys)) {
            if ($names -notcontains $k) { $docState.Remove($k); $changed = $true }
        }
        if ($changed -or $rows.Count -eq 0) { Write-DocumentStateFile $cfg $rows }
    }
    catch {
        # keep the loop alive; the next pass retries
    }
    Start-Sleep -Seconds 1
}
