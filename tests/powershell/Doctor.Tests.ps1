#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\scripts\lib\Doctor.psm1') -Force

    # Fresh deep copy of the shipped configuration for each test to mutate.
    function New-TestConfig { Get-MonitorSettings | ConvertTo-Json -Depth 30 | ConvertFrom-Json }

    function Get-Status ($Results, [string]$Status) { @($Results | Where-Object Status -eq $Status) }
}

Describe 'Test-DoctorConfig with the shipped configuration' {
    It 'reports no failures and no warnings' {
        $results = Test-DoctorConfig (New-TestConfig)
        Get-Status $results 'FAIL' | Should -BeNullOrEmpty
        Get-Status $results 'WARN' | Should -BeNullOrEmpty
        $results[0].Check | Should -Be 'Schema valid'
    }
}

Describe 'Test-DoctorConfig detects <Case>' -ForEach @(
    @{ Case = 'a zero global interval';        Check = 'global.check_interval_sec';                  Mutate = { param($c) $c.global.check_interval_sec = 0 } }
    @{ Case = 'a missing log_file';            Check = 'global.log_file';                            Mutate = { param($c) $c.global.PSObject.Properties.Remove('log_file') } }
    @{ Case = 'a process name without .exe';   Check = 'processes[0].name';                          Mutate = { param($c) $c.processes[0].name = 'explorer' } }
    @{ Case = 'a CPU percent above 100';       Check = 'performance.cpu.thresholds[0].percent';      Mutate = { param($c) $c.performance.cpu.thresholds[0].percent = 150 } }
    @{ Case = 'a negative sustain_sec';        Check = 'performance.memory.thresholds[1].sustain_sec'; Mutate = { param($c) $c.performance.memory.thresholds[1].sustain_sec = -1 } }
    @{ Case = 'a malformed drive';             Check = 'disk[0].drive';                              Mutate = { param($c) $c.disk[0].drive = 'C' } }
    @{ Case = 'a zero percent_used';           Check = 'disk[0].thresholds[0].percent_used';         Mutate = { param($c) $c.disk[0].thresholds[0].percent_used = 0 } }
    @{ Case = 'an unknown protocol';           Check = 'network[0].protocol';                        Mutate = { param($c) $c.network[0].protocol = 'udp' } }
    @{ Case = 'a TCP port out of range';       Check = 'network[1].port';                            Mutate = { param($c) $c.network[1].port = 70000 } }
    @{ Case = 'a network rule with no trigger'; Check = 'network[0].thresholds[0]';                  Mutate = { param($c) $c.network[0].thresholds[0].PSObject.Properties.Remove('latency_ms') } }
    @{ Case = 'an unknown action type';        Check = 'performance.cpu.thresholds[0].actions[0].type'; Mutate = { param($c) $c.performance.cpu.thresholds[0].actions[0].type = 'sms' } }
    @{ Case = 'an unknown level';              Check = 'disk[0].thresholds[0].level';                Mutate = { param($c) $c.disk[0].thresholds[0].level = 'info' } }
    @{ Case = 'run_script without a path';     Check = 'performance.cpu.thresholds[1].actions[2] (run_script)'; Mutate = { param($c) $c.performance.cpu.thresholds[1].actions[2].PSObject.Properties.Remove('path') } }
    @{ Case = 'email_draft without a subject'; Check = 'performance.cpu.thresholds[1].actions[1] (email_draft)'; Mutate = { param($c) $c.performance.cpu.thresholds[1].actions[1].PSObject.Properties.Remove('subject_template') } }
    @{ Case = 'a zero ebook target';           Check = 'ebook_sales.target_usd';                     Mutate = { param($c) $c.ebook_sales.target_usd = 0 } }
) {
    It 'as FAIL' {
        $cfg = New-TestConfig
        & $Mutate $cfg
        $fails = Get-Status (Test-DoctorConfig $cfg) 'FAIL'
        $fails.Check | Should -Contain $Check
    }
}

Describe 'Test-DoctorConfig conventions' {
    It 'warns when a non-process section uses instructions instead of message_template' {
        $cfg = New-TestConfig
        $act = $cfg.disk[0].thresholds[0].actions[0]
        $act | Add-Member -NotePropertyName instructions -NotePropertyValue 'x'
        $act.PSObject.Properties.Remove('message_template')
        $warn = Get-Status (Test-DoctorConfig $cfg) 'WARN'
        $warn.Detail | Should -Match "should use 'message_template'"
    }

    It 'warns when a warning-level threshold sends email' {
        $cfg   = New-TestConfig
        $email = $cfg.performance.cpu.thresholds[1].actions | Where-Object type -eq 'email_draft'
        $cfg.performance.cpu.thresholds[0].actions += $email
        $warn = Get-Status (Test-DoctorConfig $cfg) 'WARN'
        $warn.Detail | Should -Contain 'By convention only critical thresholds send email or run scripts'
    }
}

Describe 'Test-DoctorPaths' {
    BeforeEach {
        $cfg = New-TestConfig
        $cfg.global.scripts_dir = $TestDrive
        $cfg.global.log_file    = Join-Path $TestDrive 'logs\monitor.log'
        $cfg.performance.cpu.thresholds[1].actions[2].path = '{global.scripts_dir}\handler.ps1'
    }

    It 'fails when a run_script target does not exist' {
        $fails = Get-Status (Test-DoctorPaths $cfg) 'FAIL'
        $fails.Check | Should -Contain 'run_script handler.ps1'
    }

    It 'passes once the run_script target exists' {
        New-Item (Join-Path $TestDrive 'handler.ps1') -ItemType File | Out-Null
        $results = Test-DoctorPaths $cfg
        ($results | Where-Object Check -eq 'run_script handler.ps1').Status | Should -Be 'OK'
    }

    It 'warns (not fails) when the log folder does not exist yet' {
        $results = Test-DoctorPaths $cfg
        ($results | Where-Object Check -eq 'Log folder').Status | Should -Be 'WARN'
    }

    It 'fails when the ebook workbook is missing' {
        $cfg.ebook_sales.xlsx_path = Join-Path $TestDrive 'missing.xlsx'
        (Get-Status (Test-DoctorPaths $cfg) 'FAIL').Check | Should -Contain 'Ebook workbook'
    }

    It 'warns when a configured drive is not present' {
        $cfg.disk[0].drive = 'Q:\'
        $present = @(Get-CimInstance Win32_LogicalDisk | ForEach-Object DeviceID)
        if ($present -contains 'Q:') { Set-ItResult -Skipped -Because 'this machine has a Q: drive' }
        (Get-Status (Test-DoctorPaths $cfg) 'WARN').Check | Should -Contain 'Drive Q:'
    }
}

Describe 'Invoke-Doctor' {
    It 'reports invalid JSON as a single FAIL' {
        $bad = Join-Path $TestDrive 'bad.json'
        '{ "global": ' | Set-Content $bad
        $results = @(Invoke-Doctor -SettingsPath $bad -SkipRuntime -SkipEnvironment)
        $results.Count     | Should -Be 1
        $results[0].Status | Should -Be 'FAIL'
        $results[0].Check  | Should -Be 'Settings file parses'
    }
}
