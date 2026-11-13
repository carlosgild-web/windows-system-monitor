#Requires -Version 5.1
<#
.SYNOPSIS
    Sample run_script handler: CPU usage crossed its critical threshold.
.DESCRIPTION
    Called by performance_monitor.ps1 through a "run_script" action in
    monitoring_settings.json:
        on_cpu_critical.ps1 --level critical --value <percent>
    This sample only records the event in the monitor log. Replace the
    marked section with real remediation for your environment.
#>
. (Join-Path $PSScriptRoot '..\lib\ActionHandler.ps1')

$opts = ConvertFrom-HandlerArgs $args
Write-HandlerLog 'on_cpu_critical' ('Value = CPU {0}% (level {1})' -f $opts['value'], $opts['level'])

# ---- Your remediation goes here ----------------------------------------------
# Example remediation: capture the top CPU consumers for later analysis.
#   Get-Process | Sort-Object CPU -Descending | Select-Object -First 10 |
#       Out-File (Join-Path $env:TEMP 'cpu_top10.txt')
