#Requires -Version 5.1
<#
.SYNOPSIS
    Shared helpers dot-sourced by every monitor script and by doctor.ps1.
.DESCRIPTION
    - Get-MonitorSettings : loads monitoring_settings.json as UTF-8 and resolves
                            relative paths in the "global" section against the
                            project root, so the repo works from any folder.
    - Resolve-ProjectPath : turns a project-relative path into an absolute one.
#>

# $PSScriptRoot is this file's folder (scripts\lib) even when dot-sourced.
$MonitorProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))

function Resolve-ProjectPath ([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path))      { return $Path }
    if ([System.IO.Path]::IsPathRooted($Path))    { return $Path }
    return [System.IO.Path]::GetFullPath((Join-Path $MonitorProjectRoot $Path))
}

function Show-MonitorPopup ([string]$Title, [string]$Message) {
    # The MessageBox blocks until dismissed, so it runs in a separate hidden
    # PowerShell process and never stalls the monitor loop. The text travels
    # through environment variables inherited by the child, never through
    # the command line, so values from templates cannot inject code.
    $env:_PM_POPUP_TITLE   = $Title
    $env:_PM_POPUP_MESSAGE = $Message
    $cmd = 'Add-Type -AssemblyName System.Windows.Forms;' +
           '[void][System.Windows.Forms.MessageBox]::Show(' +
           '$env:_PM_POPUP_MESSAGE,$env:_PM_POPUP_TITLE,' +
           '[System.Windows.Forms.MessageBoxButtons]::OK,' +
           '[System.Windows.Forms.MessageBoxIcon]::Warning)'
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    Start-Process powershell.exe -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-EncodedCommand', $enc
}

function Get-MonitorSettings ([string]$Path = (Join-Path $MonitorProjectRoot 'monitoring_settings.json')) {
    if (-not (Test-Path $Path)) { throw "Settings file not found: $Path" }
    # -Encoding UTF8 is required: PowerShell 5.1 defaults to Windows-1252,
    # which corrupts non-ASCII characters in message templates.
    $cfg = (Get-Content $Path -Raw -Encoding UTF8) | ConvertFrom-Json
    if ($cfg.global) {
        foreach ($key in 'log_file', 'scripts_dir') {
            if ($cfg.global.PSObject.Properties[$key]) {
                $cfg.global.$key = Resolve-ProjectPath $cfg.global.$key
            }
        }
    }
    return $cfg
}
