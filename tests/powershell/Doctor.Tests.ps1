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
    @{ Case = 'a zero document target';        Check = 'document[0].target';                         Mutate = { param($c) $c.document[0].target = 0 } }
    @{ Case = 'a document without a column';   Check = 'document[0].value_column';                   Mutate = { param($c) $c.document[0].PSObject.Properties.Remove('value_column') } }
    @{ Case = 'a workbook without a sheet';    Check = 'document[0].sheet_name';                     Mutate = { param($c) $c.document[0].path = 'data\book.xlsx' } }
    @{ Case = 'an unknown document condition'; Check = 'document[0].thresholds[0].condition';        Mutate = { param($c) $c.document[0].thresholds[0].condition = 'over' } }
    @{ Case = 'a zero percent_of_target';      Check = 'document[0].thresholds[1].percent_of_target'; Mutate = { param($c) $c.document[0].thresholds[1].percent_of_target = 0 } }
    @{ Case = 'an unknown document action';    Check = 'document[0].thresholds[1].actions[0].type';  Mutate = { param($c) $c.document[0].thresholds[1].actions[0].type = 'sms' } }
    @{ Case = 'an unknown document measure';   Check = 'document[1].measure';                        Mutate = { param($c) $c.document[1].measure = 'rows' } }
    @{ Case = 'a bad size_unit';               Check = 'document[2].size_unit';                      Mutate = { param($c) $c.document[2].size_unit = 'TB' } }
    @{ Case = 'a file_size without a path';    Check = 'document[2].path';                           Mutate = { param($c) $c.document[2].PSObject.Properties.Remove('path') } }
    @{ Case = 'two documents with one name';   Check = 'document[1].display_name';                   Mutate = { param($c) $c.document[1].display_name = $c.document[0].display_name } }
    @{ Case = 'a negative email cooldown';     Check = 'global.email_cooldown_min';                  Mutate = { param($c) $c.global.email_cooldown_min = -5 } }
    @{ Case = 'a negative clear_margin';       Check = 'performance.cpu.thresholds[1].clear_margin'; Mutate = { param($c) $c.performance.cpu.thresholds[1] | Add-Member clear_margin -5 } }
    @{ Case = 'a non-numeric disk clear_sec';  Check = 'disk[0].thresholds[0].clear_sec';            Mutate = { param($c) $c.disk[0].thresholds[0] | Add-Member clear_sec 'soon' } }
    @{ Case = 'a negative network clear_sec';  Check = 'network[0].thresholds[1].clear_sec';         Mutate = { param($c) $c.network[0].thresholds[1] | Add-Member clear_sec -1 } }
) {
    It 'as FAIL' {
        $cfg = New-TestConfig
        & $Mutate $cfg
        $fails = Get-Status (Test-DoctorConfig $cfg) 'FAIL'
        $fails.Check | Should -Contain $Check
    }
}

Describe 'Test-DoctorConfig migration' {
    It 'still accepts a v1.6 single-object document section' {
        $cfg = New-TestConfig
        $cfg.document = $cfg.document[0]
        $results = Test-DoctorConfig $cfg
        Get-Status $results 'FAIL' | Should -BeNullOrEmpty
    }

    It 'does not ask a file_size document for columns' {
        $cfg = New-TestConfig
        (Get-Status (Test-DoctorConfig $cfg) 'FAIL').Check | Should -Not -Contain 'document[2].value_column'
    }

    It 'warns that a v1.5 ebook_sales section is ignored' {
        $cfg = New-TestConfig
        $cfg | Add-Member ebook_sales ([pscustomobject]@{ xlsx_path = 'x.xlsx' })
        (Get-Status (Test-DoctorConfig $cfg) 'WARN').Check | Should -Contain 'ebook_sales'
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

    It 'fails when a summed document file is missing' {
        $cfg.document[0].path = Join-Path $TestDrive 'missing.csv'
        (Get-Status (Test-DoctorPaths $cfg) 'FAIL').Check | Should -Contain "Document file ($($cfg.document[0].display_name))"
    }

    It 'only warns when a file_size document does not exist yet' {
        $cfg.document[2].path = Join-Path $TestDrive 'not-yet.log'
        $row = Test-DoctorPaths $cfg | Where-Object Check -eq "Document file ($($cfg.document[2].display_name))"
        $row.Status | Should -Be 'WARN'
    }

    It 'checks for Excel only when a workbook is summed' {
        ($results = Test-DoctorPaths $cfg) | Out-Null
        $results.Check | Should -Not -Contain 'Excel COM registered'
        $cfg.document[2].path = 'sample_data\book.xlsx'          # file_size never opens Excel
        (Test-DoctorPaths $cfg).Check | Should -Not -Contain 'Excel COM registered'
        $cfg.document[0].path = 'sample_data\book.xlsx'
        (Test-DoctorPaths $cfg).Check | Should -Contain 'Excel COM registered'
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
