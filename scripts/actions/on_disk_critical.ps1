#Requires -Version 5.1
<#
.SYNOPSIS
    Sample run_script handler: A drive crossed its critical used-space threshold.
.DESCRIPTION
    Called by monitor_disk.ps1 through a "run_script" action in
    monitoring_settings.json:
        on_disk_critical.ps1 --drive <letter:> --value <percent_used>
    This sample only records the event in the monitor log. Replace the
    marked section with real remediation for your environment.
#>
. (Join-Path $PSScriptRoot '..\lib\ActionHandler.ps1')

$opts = ConvertFrom-HandlerArgs $args
Write-HandlerLog 'on_disk_critical' ('Drive {0} at {1}% used' -f $opts['drive'], $opts['value'])

# ---- Your remediation goes here ----------------------------------------------
# Example remediation: clear the user temp folder (files older than 7 days).
#   Get-ChildItem $env:TEMP -Recurse -File -ErrorAction SilentlyContinue |
#       Where-Object LastWriteTime -lt (Get-Date).AddDays(-7) | Remove-Item -Force
