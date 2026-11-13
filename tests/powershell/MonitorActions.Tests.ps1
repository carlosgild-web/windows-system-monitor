#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $scripts = Join-Path $PSScriptRoot '..\..\scripts'
    . (Join-Path $scripts 'lib\MonitorCommon.ps1')
    . (Join-Path $scripts 'lib\MonitorActions.ps1')

    function New-GlobalCfg ([string]$LogFile, [double]$MaxMb = 50) {
        [pscustomobject]@{
            log_file        = $LogFile
            log_max_size_mb = $MaxMb
            email_recipient = 'alerts@example.com'
        }
    }
}

Describe 'Expand-Template' {
    It 'fills monitor variables and {global.<field>} values' {
        $g = New-GlobalCfg 'x.log'
        Expand-Template 'CPU {current_value}% -> {global.email_recipient}' @{ current_value = '97.5' } $g |
            Should -Be 'CPU 97.5% -> alerts@example.com'
    }

    It 'matches placeholders case-insensitively' {
        Expand-Template '{Host} down' @{ host = '8.8.8.8' } $null | Should -Be '8.8.8.8 down'
    }

    It 'inserts values literally, even with $ or regex characters' {
        Expand-Template 'share {path}' @{ path = 'C$\data $1 (x)' } $null | Should -Be 'share C$\data $1 (x)'
    }

    It 'leaves unknown placeholders alone and accepts an empty template' {
        Expand-Template '{nope}' @{ a = 1 } $null | Should -Be '{nope}'
        Expand-Template $null @{ a = 1 } $null   | Should -Be ''
    }
}

Describe 'Write-MonitorLog' {
    It 'creates the log folder and appends a UTF-8 line' {
        $log = Join-Path $TestDrive 'new\monitor.log'
        Write-MonitorLog "CPU $([char]0x2014) high" (New-GlobalCfg $log)
        Get-Content $log -Encoding UTF8 | Should -Be "CPU $([char]0x2014) high"
    }

    It 'rotates the file to monitor.<timestamp>.log once it reaches the size limit' {
        $dir = Join-Path $TestDrive 'rotate'
        New-Item $dir -ItemType Directory | Out-Null
        $log = Join-Path $dir 'monitor.log'
        Set-Content $log ('x' * 2KB)
        Write-MonitorLog 'fresh line' (New-GlobalCfg $log -MaxMb 0.001)
        Get-Content $log | Should -Be 'fresh line'
        @(Get-ChildItem $dir -Filter 'monitor.*.log').Count | Should -Be 1
    }
}

Describe 'Invoke-MonitorActions' {
    BeforeAll {
        $log = Join-Path $TestDrive 'actions\monitor.log'
        $g   = New-GlobalCfg $log
        $actions = @(
            [pscustomobject]@{ type = 'popup';       title = 'T {host}'; message_template = 'M {host}' }
            [pscustomobject]@{ type = 'log_to_file'; level = 'critical'; message_template = 'LOG {host}' }
            [pscustomobject]@{ type = 'email_draft'; to = '{global.email_recipient}'; subject_template = 'S {host}'; body_template = 'B & ?' }
        )
    }

    BeforeEach {
        Remove-Item $log -ErrorAction SilentlyContinue
        Mock Start-Process { }
        Mock Show-MonitorPopup { }
    }

    It 'runs every action on a first alert' {
        Invoke-MonitorActions -Actions $actions -Vars @{ host = 'srv1' } -GlobalCfg $g
        Should -Invoke Show-MonitorPopup -Times 1 -ParameterFilter { $Title -eq 'T srv1' -and $Message -eq 'M srv1' }
        Should -Invoke Start-Process -Times 1
        Get-Content $log | Should -Be 'LOG srv1'
    }

    It 'builds a mailto URI with every field escaped' {
        Invoke-MonitorActions -Actions $actions -Vars @{ host = 'srv1' } -GlobalCfg $g
        Should -Invoke Start-Process -Times 1 -ParameterFilter {
            $FilePath -eq 'mailto:alerts@example.com?subject=S%20srv1&body=B%20%26%20%3F'
        }
    }

    It 'skips popup and email_draft on a repeat alert (spam guard) but still logs' {
        Invoke-MonitorActions -Actions $actions -Vars @{ host = 'srv1' } -GlobalCfg $g -SuppressSpam
        Should -Invoke Show-MonitorPopup -Times 0
        Should -Invoke Start-Process -Times 0
        Get-Content $log | Should -Be 'LOG srv1'
    }

    It 'uses instructions as the popup text for process actions and logs a compact line' {
        $proc = [pscustomobject]@{ type = 'popup'; level = 'warning'; title = 'Down'; instructions = 'Runbook for {proc_display}' },
                [pscustomobject]@{ type = 'log_to_file'; level = 'warning'; instructions = 'Long runbook text' }
        $vars = @{ timestamp = '2026-11-14 09:00:00'; proc_name = 'notepad.exe'; proc_display = 'Notepad' }
        Invoke-MonitorActions -Actions $proc -Vars $vars -GlobalCfg $g
        Should -Invoke Show-MonitorPopup -Times 1 -ParameterFilter { $Message -eq 'Runbook for Notepad' }
        Get-Content $log | Should -Be '[2026-11-14 09:00:00] WARNING PROC: Notepad (notepad.exe) not detected.'
    }

    It 'runs a run_script action with expanded arguments' {
        $script = Join-Path $TestDrive 'handler.ps1'
        $out    = Join-Path $TestDrive 'handler.out'
        Set-Content $script "param([string]`$A, [string]`$B) Set-Content '$out' `"`$A|`$B`""
        $run = [pscustomobject]@{ type = 'run_script'; path = $script; args = @('{host}', 'x') }
        Invoke-MonitorActions -Actions $run -Vars @{ host = 'srv1' } -GlobalCfg $g -SuppressSpam
        Get-Content $out | Should -Be 'srv1|x'
    }

    It 'keeps going when one action fails' {
        Mock Show-MonitorPopup { throw 'no desktop' }
        { Invoke-MonitorActions -Actions $actions -Vars @{ host = 'srv1' } -GlobalCfg $g } | Should -Not -Throw
        Get-Content $log | Should -Be 'LOG srv1'
        Should -Invoke Start-Process -Times 1
    }
}
