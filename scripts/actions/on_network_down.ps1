#Requires -Version 5.1
<#
.SYNOPSIS
    Sample run_script handler: A network target stopped responding.
.DESCRIPTION
    Called by monitor_network.ps1 through a "run_script" action in
    monitoring_settings.json:
        on_network_down.ps1 --host <host>
    This sample only records the event in the monitor log. Replace the
    marked section with real remediation for your environment.
#>
. (Join-Path $PSScriptRoot '..\lib\ActionHandler.ps1')

$opts = ConvertFrom-HandlerArgs $args
Write-HandlerLog 'on_network_down' ('Host {0} unreachable' -f $opts['host'])

# ---- Your remediation goes here ----------------------------------------------
# Example remediation: save a traceroute for the network team (run detached
# so the monitor loop is not blocked).
#   Start-Process tracert -ArgumentList $opts['host'] -WindowStyle Hidden `
#       -RedirectStandardOutput (Join-Path $env:TEMP 'tracert.txt')
