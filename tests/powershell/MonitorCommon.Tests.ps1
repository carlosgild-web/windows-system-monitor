#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $scripts = Join-Path $PSScriptRoot '..\..\scripts'
    . (Join-Path $scripts 'lib\MonitorCommon.ps1')
    . (Join-Path $scripts 'lib\ActionHandler.ps1')
    $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
}

Describe 'Resolve-ProjectPath' {
    It 'resolves a relative path against the project root' {
        Resolve-ProjectPath 'logs\monitor.log' | Should -Be (Join-Path $root 'logs\monitor.log')
    }
    It 'leaves an absolute path unchanged' {
        Resolve-ProjectPath 'D:\data\monitor.log' | Should -Be 'D:\data\monitor.log'
    }
    It 'returns empty input unchanged' {
        Resolve-ProjectPath '' | Should -Be ''
    }
}

Describe 'Get-MonitorSettings' {
    It 'resolves relative global paths and keeps absolute ones' {
        $file = Join-Path $TestDrive 'settings.json'
        '{ "global": { "log_file": "logs\\monitor.log", "scripts_dir": "C:\\ops\\scripts" } }' |
            Set-Content $file -Encoding UTF8
        $cfg = Get-MonitorSettings $file
        $cfg.global.log_file    | Should -Be (Join-Path $root 'logs\monitor.log')
        $cfg.global.scripts_dir | Should -Be 'C:\ops\scripts'
    }

    It 'reads the file as UTF-8 (non-ASCII text survives)' {
        $file  = Join-Path $TestDrive 'utf8.json'
        $dash  = [char]0x2014
        $accent = [char]0x00E9
        $json  = '{ "note": "CPU ' + $dash + ' caf' + $accent + '" }'
        [System.IO.File]::WriteAllText($file, $json, (New-Object System.Text.UTF8Encoding $false))
        (Get-MonitorSettings $file).note | Should -Be ("CPU $dash caf$accent")
    }

    It 'throws a clear error when the file is missing' {
        { Get-MonitorSettings (Join-Path $TestDrive 'missing.json') } | Should -Throw '*Settings file not found*'
    }

    It 'loads the shipped monitoring_settings.json' {
        $cfg = Get-MonitorSettings
        $cfg._meta.version | Should -Not -BeNullOrEmpty
        [System.IO.Path]::IsPathRooted($cfg.global.log_file) | Should -BeTrue
    }
}

Describe 'Show-MonitorPopup' {
    It 'shows the dialog from a hidden child process, passing text via environment variables' {
        Mock Start-Process { }
        Show-MonitorPopup 'Disk alert' 'C: is "full"; $(calc)'
        Should -Invoke Start-Process -Times 1 -ParameterFilter {
            $enc = $ArgumentList[$ArgumentList.IndexOf('-EncodedCommand') + 1]
            $cmd = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($enc))
            $FilePath -eq 'powershell.exe' -and
            $ArgumentList -contains 'Hidden' -and
            $cmd -match 'MessageBox' -and
            $cmd -notmatch 'calc'          # message text never reaches the command line
        }
        $env:_PM_POPUP_TITLE   | Should -Be 'Disk alert'
        $env:_PM_POPUP_MESSAGE | Should -Be 'C: is "full"; $(calc)'
    }
}

Describe 'ConvertFrom-HandlerArgs' {
    It 'parses --key value pairs' {
        $m = ConvertFrom-HandlerArgs @('--level', 'critical', '--value', '97.5')
        $m['level'] | Should -Be 'critical'
        $m['value'] | Should -Be '97.5'
    }
    It 'treats a key without a value as a switch' {
        $m = ConvertFrom-HandlerArgs @('--dry-run', '--host', '8.8.8.8')
        $m['dry-run'] | Should -BeTrue
        $m['host']    | Should -Be '8.8.8.8'
    }
    It 'returns an empty map for no arguments' {
        (ConvertFrom-HandlerArgs @()).Count | Should -Be 0
    }
}
