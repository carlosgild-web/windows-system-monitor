#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $scripts = Join-Path $PSScriptRoot '..\..\scripts'
    . (Join-Path $scripts 'lib\MonitorCommon.ps1')
    . (Join-Path $scripts 'lib\MonitorActions.ps1')
    # The email cooldown starts over when the settings file is saved after the last email.
    # Point it away from the real file, which changes whenever someone edits the settings.
    $MonitorSettingsFile = Join-Path $TestDrive 'no-settings.json'

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
        Mock Open-TicketWindow { }
    }

    It 'runs every action on a first alert' {
        Invoke-MonitorActions -Actions $actions -Vars @{ host = 'srv1' } -GlobalCfg $g
        Should -Invoke Show-MonitorPopup -Times 1 -ParameterFilter { $Title -eq 'T srv1' -and $Message -eq 'M srv1' }
        Should -Invoke Open-TicketWindow -Times 1
        Should -Invoke Start-Process -Times 0          # the email waits in the ticket preview
        Get-Content $log | Should -Be 'LOG srv1'
    }

    It 'builds a mailto URI with every field escaped' {
        Get-MailtoUri 'alerts@example.com' 'S srv1' 'B & ?' | Should -Be 'mailto:alerts@example.com?subject=S%20srv1&body=B%20%26%20%3F'
        Get-MailtoUri 'a@x.com?cc=b@y.com' 's' 'b' | Should -BeLike 'mailto:a@x.com%3Fcc%3Db@y.com?subject=*'
    }

    It 'shows the email as a ticket preview that carries the mailto link' {
        Invoke-MonitorActions -Actions $actions -Vars @{ host = 'srv1' } -GlobalCfg $g -AlertKey 'disk|C:\|critical'
        Should -Invoke Open-TicketWindow -Times 1 -ParameterFilter { $Path -like '*\tickets\INC*.html' }
        $html = Get-ChildItem (Join-Path $TestDrive 'actions\tickets') -Filter 'INC*.html' | Sort-Object Name | Select-Object -Last 1 | Get-Content -Raw
        # ConvertTo-Json escapes the '&' between the fields, so check the parts on each side of it.
        $html | Should -Match ([regex]::Escape('"mailto":"mailto:alerts@example.com?subject=S%20srv1'))
        $html | Should -Match ([regex]::Escape('body=B%20%26%20%3F"'))
    }

    It 'opens the email directly when the ticket preview cannot be shown' {
        Mock New-TicketPreview { throw 'no template' }
        Invoke-MonitorActions -Actions $actions -Vars @{ host = 'srv1' } -GlobalCfg $g
        Should -Invoke Open-TicketWindow -Times 0
        Should -Invoke Start-Process -Times 1 -ParameterFilter {
            $FilePath -eq 'mailto:alerts@example.com?subject=S%20srv1&body=B%20%26%20%3F'
        }
    }

    It 'skips popup and email_draft on a repeat alert (spam guard) but still logs' {
        Invoke-MonitorActions -Actions $actions -Vars @{ host = 'srv1' } -GlobalCfg $g -SuppressSpam
        Should -Invoke Show-MonitorPopup -Times 0
        Should -Invoke Open-TicketWindow -Times 0
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
        Should -Invoke Open-TicketWindow -Times 1
    }
}

Describe 'Ticket preview' {
    BeforeAll {
        $g = New-GlobalCfg (Join-Path $TestDrive 'tk\monitor.log')
        $g | Add-Member email_sender 'monitor@example.com'
        function Get-TicketData ([string]$Path) {
            $html = Get-Content $Path -Raw -Encoding UTF8
            $m = [regex]::Match($html, 'const T = (\{.*?\});')
            $m.Success | Should -BeTrue
            return ($m.Groups[1].Value | ConvertFrom-Json)
        }
    }

    It 'numbers tickets INC0010001, INC0010002, ...' {
        $dir = Join-Path $TestDrive 'numbers'
        Get-NextTicketNumber $dir | Should -Be 'INC0010001'
        Get-NextTicketNumber $dir | Should -Be 'INC0010002'
    }

    It 'splits the alert key into monitor, item and level' -ForEach @(
        @{ Key = 'performance|memory|critical'; Monitor = 'performance'; Item = 'memory'; Level = 'critical' }
        @{ Key = 'document|Groceries|warning';  Monitor = 'document';    Item = 'Groceries'; Level = 'warning' }
        @{ Key = 'process|notepad.exe';         Monitor = 'process';     Item = 'notepad.exe'; Level = 'critical' }
        @{ Key = '';                            Monitor = 'monitoring';  Item = '';          Level = 'critical' }
    ) {
        $k = Split-AlertKey $Key
        $k.Monitor | Should -Be $Monitor
        $k.Item    | Should -Be $Item
        $k.Level   | Should -Be $Level
    }

    It 'fills the template with the alert, and text cannot break out of the script block' {
        $t = New-TicketPreview -AlertKey 'performance|memory|warning' -To 'a@example.com' -Subject 'RAM </script><b>x' `
            -Body "line 1`nline 2" -Mailto 'mailto:a@example.com' -Vars @{ timestamp = '2026-11-14 10:00:00'; hostname = 'PC-01' } -GlobalCfg $g
        $t.Path | Should -Exist
        $html = Get-Content $t.Path -Raw -Encoding UTF8
        $html | Should -Not -Match '/\*TICKET_DATA\*/null'
        $html | Should -Not -Match '</script><b>'
        $d = Get-TicketData $t.Path
        $d.number   | Should -Be $t.Number
        $d.level    | Should -Be 'warning'
        $d.monitor  | Should -Be 'performance'
        $d.item     | Should -Be 'memory'
        $d.hostname | Should -Be 'PC-01'
        $d.opened   | Should -Be '2026-11-14 10:00:00'
        $d.subject  | Should -Be 'RAM </script><b>x'
        $d.body     | Should -Be "line 1`nline 2"
        $d.from     | Should -Be 'monitor@example.com'
    }

    It 'fails clearly when the template is missing' {
        { New-TicketPreview -AlertKey 'disk|C:|critical' -To 'a@example.com' -Subject 's' -Body 'b' -Mailto 'mailto:a' `
            -Vars @{} -GlobalCfg $g -Template (Join-Path $TestDrive 'nope.html') } | Should -Throw '*template not found*'
    }

    It 'keeps the shipped template marker in place' {
        $template = Join-Path $PSScriptRoot '..\..\web\ticket.html'
        (Get-Content $template -Raw -Encoding UTF8) | Should -Match ([regex]::Escape('const T = /*TICKET_DATA*/null;'))
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

    It 'starts over when the settings are saved after the last email' {
        $settings = Join-Path $TestDrive 'settings-saved.json'
        Set-Content $settings '{}'
        (Get-Item $settings).LastWriteTime = $t0.AddMinutes(-10)
        $MonitorSettingsFile = $settings
        Request-EmailSlot 'document|Log|critical' $g $t0               | Should -BeTrue
        Request-EmailSlot 'document|Log|critical' $g $t0.AddMinutes(2) | Should -BeFalse   # saved before: still blocked
        (Get-Item $settings).LastWriteTime = $t0.AddMinutes(3)
        Request-EmailSlot 'document|Log|critical' $g $t0.AddMinutes(4) | Should -BeTrue    # saved since: allowed
        Request-EmailSlot 'document|Log|critical' $g $t0.AddMinutes(5) | Should -BeFalse   # and the cooldown runs again
    }

    It 'allows the email when the state file is corrupt' {
        New-Item $dir -ItemType Directory | Out-Null
        Set-Content (Join-Path $dir 'alert_state.json') '{ not json'
        Request-EmailSlot 'k' $g $t0 | Should -BeTrue
    }
}

Describe 'Get-TicketWindowBounds' {
    It 'uses 900 x 880 centered when the screen has room' {
        $b = Get-TicketWindowBounds -Left 0 -Top 0 -Width 1920 -Height 1040
        $b.Width | Should -Be 900; $b.Height | Should -Be 880
        $b.X | Should -Be 510; $b.Y | Should -Be 80
    }

    It 'fits a laptop work area (1536 x 816 at 125 % scaling)' {
        $b = Get-TicketWindowBounds -Left 0 -Top 0 -Width 1536 -Height 816
        $b.Height | Should -Be 768
        ($b.Y + $b.Height) | Should -BeLessOrEqual 816
    }

    It 'centers on a second screen and keeps a minimum size' {
        $b = Get-TicketWindowBounds -Left 1920 -Top 0 -Width 400 -Height 300
        $b.Width | Should -Be 480; $b.Height | Should -Be 400
        $b.X | Should -Be 1920; $b.Y | Should -Be 0
    }

    It 'falls back to 900 x 880 when the screen is unknown' {
        $b = Get-TicketWindowBounds
        $b.Width | Should -Be 900; $b.Height | Should -Be 880
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
                    Value = $Value; Threshold = [double]$t.Pct
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
        Mock Open-TicketWindow { }
    }

    It 'opens one email draft while RAM hovers around 95% for ten minutes' {
        $trackers = @{}
        Invoke-RamSeries (@(96) * 7 + @(94.8, 95.2, 94.9, 95.3) * 30) $trackers $t0 $g
        Should -Invoke Open-TicketWindow -Times 1 -Exactly
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
        Should -Invoke Open-TicketWindow -Times 1 -Exactly
        @(Get-Content $log | Where-Object { $_ -like '*email_draft for performance|memory|critical skipped*' }).Count | Should -Be 1
    }

    It 'opens a new ticket when the settings were saved between two incidents' {
        # what a person testing does: alert, change the threshold in the editor, alert again
        $settings = Join-Path $dir 'settings.json'
        New-Item $dir -ItemType Directory -Force | Out-Null
        Set-Content $settings '{}'
        # the cooldown stamps emails with the real clock, so the save times are real-clock too
        (Get-Item $settings).LastWriteTime = (Get-Date).AddMinutes(-30)
        $MonitorSettingsFile = $settings
        $trackers = @{}
        Invoke-RamSeries (@(96) * 7 + @(70) * 12) $trackers $t0 $g
        (Get-Item $settings).LastWriteTime = (Get-Date).AddSeconds(5)
        Invoke-RamSeries (@(96) * 7) $trackers $t0.AddSeconds(95) $g
        Should -Invoke Open-TicketWindow -Times 2 -Exactly
    }

    It 'opens a draft for every new incident when the cooldown is off' {
        $g.email_cooldown_min = 0
        $trackers = @{}
        Invoke-RamSeries (@(96) * 7 + @(70) * 12 + @(96) * 7) $trackers $t0 $g
        Should -Invoke Open-TicketWindow -Times 2 -Exactly
    }
}

Describe 'Open incidents (Get-OpenIncident)' {
    BeforeAll {
        function New-Check ([string]$Level, [double]$Pct, $Value, [switch]$Below) {
            $exceeded = if ($null -eq $Value) { $true } elseif ($Below) { $Value -lt $Pct } else { $Value -ge $Pct }
            $clear    = if ($null -eq $Value) { $false } elseif ($Below) { $Value -ge ($Pct + 5) } else { $Value -lt ($Pct - 5) }
            @{
                Level = $Level; SustainSec = 30; ClearSec = 0; Exceeded = $exceeded; BelowClear = $clear
                Value = $Value; Threshold = $Pct; Below = [bool]$Below
                Actions = @([pscustomobject]@{ type = 'log_to_file'; level = $Level; message_template = "$Level {current_value}" })
                Vars = @{ current_value = [string]$Value }
            }
        }
    }

    BeforeEach {
        $g  = New-GlobalCfg (Join-Path (Join-Path $TestDrive ([guid]::NewGuid())) 'monitor.log')
        $t0 = Get-Date '2026-11-14 10:00:00'
        $tr = @{}
    }

    It 'lists nothing until sustain_sec has passed' {
        $null = Invoke-ThresholdAlerts -Checks @(New-Check 'critical' 95 97) -Trackers $tr -Now $t0 -GlobalCfg $g -KeyPrefix 'performance|cpu'
        @(Get-OpenIncident $tr 'performance|cpu') | Should -BeNullOrEmpty
    }

    It 'records the start, the sustain, the threshold and the peak of an open incident' {
        foreach ($s in 0, 10, 20, 30, 40, 50) {
            $v = @{ 0 = 96; 10 = 97; 20 = 96; 30 = 98.5; 40 = 99.1; 50 = 97.2 }[$s]
            $null = Invoke-ThresholdAlerts -Checks @(New-Check 'critical' 95 $v) -Trackers $tr -Now $t0.AddSeconds($s) -GlobalCfg $g -KeyPrefix 'performance|cpu'
        }
        $inc = @(Get-OpenIncident $tr 'performance|cpu')
        $inc.Count             | Should -Be 1
        $inc[0].id             | Should -Be 'performance:cpu:critical'
        $inc[0].monitor        | Should -Be 'performance'
        $inc[0].target         | Should -Be 'cpu'
        $inc[0].exceeded_since | Should -Be '2026-11-14 10:00:00'
        $inc[0].opened_at      | Should -Be '2026-11-14 10:00:30'
        $inc[0].sustain_sec    | Should -Be 30
        $inc[0].threshold      | Should -Be 95
        $inc[0].peak           | Should -Be 99.1
        $inc[0].last_value     | Should -Be 97.2
        $inc[0].alert_count    | Should -Be 3
    }

    It 'forgets the incident when it closes, and starts fresh on the next one' {
        $null = Invoke-ThresholdAlerts -Checks @(New-Check 'critical' 95 99) -Trackers $tr -Now $t0 -GlobalCfg $g -KeyPrefix 'disk|C:\'
        $null = Invoke-ThresholdAlerts -Checks @(New-Check 'critical' 95 99) -Trackers $tr -Now $t0.AddSeconds(30) -GlobalCfg $g -KeyPrefix 'disk|C:\'
        $null = Invoke-ThresholdAlerts -Checks @(New-Check 'critical' 95 50) -Trackers $tr -Now $t0.AddSeconds(40) -GlobalCfg $g -KeyPrefix 'disk|C:\'
        @(Get-OpenIncident $tr 'disk|C:\') | Should -BeNullOrEmpty
        $null = Invoke-ThresholdAlerts -Checks @(New-Check 'critical' 95 96) -Trackers $tr -Now $t0.AddSeconds(100) -GlobalCfg $g -KeyPrefix 'disk|C:\'
        $null = Invoke-ThresholdAlerts -Checks @(New-Check 'critical' 95 96) -Trackers $tr -Now $t0.AddSeconds(130) -GlobalCfg $g -KeyPrefix 'disk|C:\'
        $inc = @(Get-OpenIncident $tr 'disk|C:\')
        $inc[0].id        | Should -Be 'disk:C:\:critical'
        $inc[0].peak      | Should -Be 96
        $inc[0].opened_at | Should -Be '2026-11-14 10:02:10'
    }

    It 'takes the lowest value as the peak of a "below" threshold' {
        foreach ($s in 0, 30, 60) {
            $v = @{ 0 = 70; 30 = 55; 60 = 62 }[$s]
            $null = Invoke-ThresholdAlerts -Checks @(New-Check 'warning' 80 $v -Below) -Trackers $tr -Now $t0.AddSeconds($s) -GlobalCfg $g -KeyPrefix 'document|Sales'
        }
        @(Get-OpenIncident $tr 'document|Sales')[0].peak | Should -Be 55
    }

    It 'keeps a null value (an unreachable host) without a peak' {
        foreach ($s in 0, 30) {
            $null = Invoke-ThresholdAlerts -Checks @(New-Check 'critical' 0 $null) -Trackers $tr -Now $t0.AddSeconds($s) -GlobalCfg $g -KeyPrefix 'network|Internet'
        }
        $inc = @(Get-OpenIncident $tr 'network|Internet')[0]
        $inc.id         | Should -Be 'network:Internet:critical'
        $inc.peak       | Should -BeNullOrEmpty
        $inc.last_value | Should -BeNullOrEmpty
    }

    It 'serializes to the JSON the state files carry' {
        foreach ($s in 0, 30) {
            $null = Invoke-ThresholdAlerts -Checks @(New-Check 'critical' 95 97) -Trackers $tr -Now $t0.AddSeconds($s) -GlobalCfg $g -KeyPrefix 'performance|memory'
        }
        $json = [ordered]@{ incidents = @(Get-OpenIncident $tr 'performance|memory') } | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        @($json.incidents).Count | Should -Be 1
        $json.incidents[0].level | Should -Be 'critical'
        @($json.incidents[0].PSObject.Properties.Name) | Should -Be @('id', 'monitor', 'target', 'level', 'opened_at', 'exceeded_since',
            'sustain_sec', 'threshold', 'peak', 'last_value', 'alert_count')
    }
}
