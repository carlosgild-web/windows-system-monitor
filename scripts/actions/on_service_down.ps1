#Requires -Version 5.1
<#
.SYNOPSIS
    Sample run_script handler: A local TCP service stopped accepting connections.
.DESCRIPTION
    Called by monitor_network.ps1 through a "run_script" action in
    monitoring_settings.json:
        on_service_down.ps1 --port <port>
    This sample only records the event in the monitor log. Replace the
    marked section with real remediation for your environment.
#>
. (Join-Path $PSScriptRoot '..\lib\ActionHandler.ps1')

$opts = ConvertFrom-HandlerArgs $args
Write-HandlerLog 'on_service_down' ('Service on port {0} not responding' -f $opts['port'])

# ---- Your remediation goes here ----------------------------------------------
# Example remediation: restart the Windows service behind the port.
#   Restart-Service -Name 'MyWebService' -ErrorAction SilentlyContinue
