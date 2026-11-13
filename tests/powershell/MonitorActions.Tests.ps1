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

Describe 'Request-EmailSlot (email cooldown)' {
    BeforeEach {
        $dir = Join-Path $TestDrive ([guid]::NewGuid())
        $g   = New-GlobalCfg (Join-Path $dir 'monitor.log')
        $g | Add-Member email_cooldown_min 60
        $t0  = Get-Date '2026-11-14 10:00:00'
    }

    It 'allows the first email and blocks a second one inside the cooldown' {
        Request-EmailSlot 'performance|memory|critical' $g $t0                | Should -BeTrue
        Request-EmailSlot 'performance|memory|critical' $g $t0.AddMinutes(59) | Should -BeFalse
    }

    It 'allows the next email once the cooldown has passed' {
        Request-EmailSlot 'disk|C:\|critical' $g $t0                | Should -BeTrue
        Request-EmailSlot 'disk|C:\|critical' $g $t0.AddMinutes(61) | Should -BeTrue
    }

    It 'tracks each key separately' {
        Request-EmailSlot 'performance|cpu|critical'    $g $t0 | Should -BeTrue
        Request-EmailSlot 'performance|memory|critical' $g $t0 | Should -BeTrue
    }

    It 'saves the time in alert_state.json, so a restarted monitor still respects it' {
        Request-EmailSlot 'process|notepad.exe' $g $t0 | Should -BeTrue
        $saved = Get-Content (Join-Path $dir 'alert_state.json') -Raw | ConvertFrom-Json
        $saved.email_sent.'process|notepad.exe' | Should -Be '2026-11-14 10:00:00'
        # a restarted monitor has nothing in memory; only the file
        Request-EmailSlot 'process|notepad.exe' $g $t0.AddMinutes(5) | Should -BeFalse
    }

    It 'is off when email_cooldown_min is 0, and defaults to 60 when missing' {
        $g.email_cooldown_min = 0
        Request-EmailSlot 'k' $g $t0 | Should -BeTrue
        Request-EmailSlot 'k' $g $t0 | Should -BeTrue
        Test-Path (Join-Path $dir 'alert_state.json') | Should -BeFalse
        Get-EmailCooldownMinutes (New-GlobalCfg 'x.log') | Should -Be 60
    }

    It 'allows the email when the state file is corrupt' {
        New-Item $dir -ItemType Directory | Out-Null
        Set-Content (Join-Path $dir 'alert_state.json') '{ not json'
        Request-EmailSlot 'k' $g $t0 | Should -BeTrue
    }
}

Describe 'Step-AlertTracker (hysteresis)' {
    BeforeAll { $t0 = Get-Date '2026-11-14 10:00:00' }

    It 'opens an incident only after sustain_sec above the threshold' {
        $tr = New-AlertTracker
        Step-AlertTracker $tr $true $false $t0                -SustainSec 30 | Should -Be 'none'
        Step-AlertTracker $tr $true $false $t0.AddSeconds(25) -SustainSec 30 | Should -Be 'none'
        Step-AlertTracker $tr $true $false $t0.AddSeconds(30) -SustainSec 30 | Should -Be 'first'
    }

    It 'restarts the sustain timer when the value dips before the incident opens' {
        $tr = New-AlertTracker
        Step-AlertTracker $tr $true  $false $t0                -SustainSec 30 | Out-Null
        Step-AlertTracker $tr $false $false $t0.AddSeconds(20) -SustainSec 30 | Out-Null
        Step-AlertTracker $tr $true  $false $t0.AddSeconds(35) -SustainSec 30 | Should -Be 'none'
    }

    It 'reports a repeat while an open incident stays above the threshold' {
        $tr = New-AlertTracker; $tr.Active = $true
        Step-AlertTracker $tr $true $false $t0 -SustainSec 30 | Should -Be 'repeat'
    }

    It 'keeps an open incident open between the clear point and the threshold' {
        $tr = New-AlertTracker; $tr.Active = $true
        foreach ($s in 0..20) {
            Step-AlertTracker $tr $false $false $t0.AddSeconds($s * 10) -ClearSec 30 | Out-Null
        }
        $tr.Active | Should -BeTrue
    }

    It 'closes the incident after clear_sec below the clear point' {
        $tr = New-AlertTracker; $tr.Active = $true; $tr.AlertCount = 4
        Step-AlertTracker $tr $false $true $t0                -ClearSec 30 | Out-Null
        $tr.Active | Should -BeTrue
        Step-AlertTracker $tr $false $true $t0.AddSeconds(30) -ClearSec 30 | Out-Null
        $tr.Active     | Should -BeFalse
        $tr.AlertCount | Should -Be 0
    }
}

Describe 'Invoke-ThresholdAlerts' {
    BeforeAll {
        function New-RamChecks ([double]$Value) {
            # Like the shipped memory thresholds: warning 85 / critical 95, sustain 30 s, margin 5.
            foreach ($t in @(@{ Level = 'warning'; Pct = 85 }, @{ Level = 'critical'; Pct = 95 })) {
                $actions = @([pscustomobject]@{ type = 'log_to_file'; level = $t.Level; message_template = "$($t.Level) {current_value}" })
                if ($t.Level -eq 'critical') {
                    $actions += [pscustomobject]@{ type = 'email_draft'; to = 'a@example.com'; subject_template = 'RAM'; body_template = '{current_value}' }
                    $actions += [pscustomobject]@{ type = 'popup'; title = 'RAM'; message_template = '{current_value}' }
                }
                @{
                    Level = $t.Level; Actions = $actions; SustainSec = 30; ClearSec = 30
                    Exceeded = ($Value -ge $t.Pct); BelowClear = ($Value -lt ($t.Pct - 5))
                    Vars = @{ current_value = [string]$Value }
                }
            }
        }
        function Invoke-RamSeries ([double[]]$Values, [hashtable]$Trackers, [datetime]$Start, $GlobalCfg) {
            # one check every 5 seconds, like the shipped performance monitor
            for ($i = 0; $i -lt $Values.Count; $i++) {
                $null = Invoke-ThresholdAlerts -Checks @(New-RamChecks $Values[$i]) -Trackers $Trackers `
                    -Now $Start.AddSeconds($i * 5) -GlobalCfg $GlobalCfg -KeyPrefix 'performance|memory'
            }
        }
    }

    BeforeEach {
        $dir = Join-Path $TestDrive ([guid]::NewGuid())
        $log = Join-Path $dir 'monitor.log'
        $g   = New-GlobalCfg $log
        $g | Add-Member email_cooldown_min 60
        $t0  = Get-Date '2026-11-14 10:00:00'
        Mock Start-Process { }
        Mock Show-MonitorPopup { }
    }

    It 'opens one email draft while RAM hovers around 95% for ten minutes' {
        $trackers = @{}
        Invoke-RamSeries (@(96) * 7 + @(94.8, 95.2, 94.9, 95.3) * 30) $trackers $t0 $g
        Should -Invoke Start-Process -Times 1 -Exactly
        Should -Invoke Show-MonitorPopup -Times 1 -Exactly
        $trackers['critical'].Active | Should -BeTrue
    }

    It 'does not fire the warning while the critical incident is still open' {
        $trackers = @{}
        Invoke-RamSeries (@(96) * 7 + @(92) * 20) $trackers $t0 $g
        @(Get-Content $log | Where-Object { $_ -like 'warning*' }) | Should -BeNullOrEmpty
    }

    It 'skips the email for a new incident inside the cooldown and logs why' {
        $trackers = @{}
        # incident 1, a minute clearly back to normal, then incident 2
        Invoke-RamSeries (@(96) * 7 + @(70) * 12 + @(96) * 7) $trackers $t0 $g
        Should -Invoke Show-MonitorPopup -Times 2 -Exactly
        Should -Invoke Start-Process -Times 1 -Exactly
        @(Get-Content $log | Where-Object { $_ -like '*email_draft for performance|memory|critical skipped*' }).Count | Should -Be 1
    }

    It 'opens a draft for every new incident when the cooldown is off' {
        $g.email_cooldown_min = 0
        $trackers = @{}
        Invoke-RamSeries (@(96) * 7 + @(70) * 12 + @(96) * 7) $trackers $t0 $g
        Should -Invoke Start-Process -Times 2 -Exactly
    }
}
