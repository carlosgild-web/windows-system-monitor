#Requires -Version 5.1
<#
.SYNOPSIS
    Diagnoses the monitoring solution: environment, configuration, paths and
    running monitors. Read-only; it never changes files or processes.
.PARAMETER SettingsFile
    Settings file to check. Default: monitoring_settings.json in the project root.
.PARAMETER SkipRuntime
    Skip the running-monitor checks (used by the start_monitoring preflight).
.OUTPUTS
    Exit code = number of FAIL results (0 = healthy).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\doctor.ps1
#>
param(
    [string]$SettingsFile,
    [switch]$SkipRuntime
)

$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'lib\Doctor.psm1') -Force

$divider = '  ' + ('=' * 60)
Write-Host ''
Write-Host $divider -ForegroundColor DarkCyan
Write-Host '   Monitoring Doctor  |  health check' -ForegroundColor Cyan
Write-Host $divider -ForegroundColor DarkCyan

$results = Invoke-Doctor -SettingsPath $SettingsFile -SkipRuntime:$SkipRuntime
Write-DoctorReport $results

$fail = @($results | Where-Object Status -eq 'FAIL').Count
$warn = @($results | Where-Object Status -eq 'WARN').Count
$ok   = @($results | Where-Object Status -eq 'OK').Count

Write-Host ''
Write-Host $divider -ForegroundColor DarkCyan
$color = if ($fail -gt 0) { 'Red' } elseif ($warn -gt 0) { 'Yellow' } else { 'Green' }
Write-Host ("   {0} OK   {1} WARN   {2} FAIL" -f $ok, $warn, $fail) -ForegroundColor $color
Write-Host $divider -ForegroundColor DarkCyan
Write-Host ''

exit $fail
