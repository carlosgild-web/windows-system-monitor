#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Static checks that enforce the PowerShell rules in CLAUDE.md on every script.

BeforeDiscovery {
    $root    = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    $scripts = Get-ChildItem -Path (Join-Path $root 'scripts') -Recurse -Include '*.ps1', '*.psm1' |
        ForEach-Object { @{ Name = $_.FullName.Substring($root.Path.Length + 1); Path = $_.FullName } }
    $monitors = 'process_monitor.ps1', 'performance_monitor.ps1', 'monitor_disk.ps1', 'monitor_network.ps1' |
        ForEach-Object { @{ Name = $_; Path = Join-Path $root "scripts\$_" } }
}

Describe 'Monitor <Name> action dispatch' -ForEach $monitors {
    It 'handles every action type the config schema allows' {
        $t = $null; $e = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$t, [ref]$e)
        $switch = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.SwitchStatementAst] -and
            $n.Condition.Extent.Text -match '\.type'
        }, $true) | Select-Object -First 1
        $switch | Should -Not -BeNullOrEmpty
        $handled = @($switch.Clauses | ForEach-Object { $_.Item1.Value })
        foreach ($type in 'popup', 'log_to_file', 'email_draft', 'run_script') {
            $handled | Should -Contain $type -Because 'an unhandled type is silently ignored at runtime'
        }
    }
}

Describe 'PowerShell script <Name>' -ForEach $scripts {
    BeforeAll {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    }

    It 'parses without syntax errors' {
        $errors | Should -BeNullOrEmpty
    }

    It 'has no non-ASCII characters in string literals (PS 5.1 reads files as Windows-1252)' {
        $strings = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
            $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
        }, $true)
        $bad = @($strings | Where-Object { $_.Extent.Text -match '[^\x00-\x7F]' } |
            ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Extent.Text)" })
        $bad | Should -BeNullOrEmpty -Because 'use [char]0xXXXX for Unicode symbols'
    }

    It 'does not assign to automatic variables such as $PID or $Matches' {
        # ($null = ... is the idiomatic way to discard output, so it is allowed.)
        $reserved = 'PID', 'PSHOME', 'HOST', 'Matches', 'Input', 'Args', 'PSItem', 'Error'
        $targets  = @()
        $targets += $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true) |
            ForEach-Object { $_.Variable }
        $targets += $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) |
            ForEach-Object { $_.Left } |
            Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] }
        $bad = @($targets | Where-Object { $_.VariablePath.UserPath -in $reserved } |
            ForEach-Object { "line $($_.Extent.StartLineNumber): `$$($_.VariablePath.UserPath)" })
        $bad | Should -BeNullOrEmpty
    }

    It 'does not enable Set-StrictMode -Version Latest (it kills the monitor loop)' {
        $calls = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Set-StrictMode'
        }, $true)
        @($calls | Where-Object { $_.Extent.Text -match 'Latest' }) | Should -BeNullOrEmpty
    }
}
