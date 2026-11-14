#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

BeforeAll {
    $scripts = Join-Path $PSScriptRoot '..\..\scripts'
    . (Join-Path $scripts 'lib\MonitorCommon.ps1')
    . (Join-Path $scripts 'lib\MonitorActions.ps1')
    . (Join-Path $scripts 'lib\DocumentReader.ps1')

    function New-Csv ([string]$Name, [string[]]$Lines, [switch]$Bom) {
        $path = Join-Path $TestDrive $Name
        [System.IO.File]::WriteAllLines($path, $Lines, (New-Object System.Text.UTF8Encoding ([bool]$Bom)))
        return $path
    }
}

Describe 'ConvertTo-DocumentNumber' {
    It 'reads <Text> as <Expected>' -ForEach @(
        @{ Text = '342.65';    Expected = 342.65 }
        @{ Text = '$1,234.50'; Expected = 1234.5 }
        @{ Text = '12,5';      Expected = 12.5 }
        @{ Text = ' -8 ';      Expected = -8 }
    ) {
        ConvertTo-DocumentNumber $Text | Should -Be $Expected
    }

    It 'returns $null for text that is not a number' {
        ConvertTo-DocumentNumber 'n/a' | Should -BeNullOrEmpty
        ConvertTo-DocumentNumber ''    | Should -BeNullOrEmpty
    }
}

Describe 'Read-CsvTotal' {
    It 'sums the value column over the matching rows' {
        $csv = New-Csv 'a.csv' @('Date,Category,Amount', '2026-11-01,Groceries,10.50', '2026-11-02,Rent,900', '2026-11-03,Groceries,4.25')
        $r = Read-CsvTotal $csv 'Category' 'Groceries' 'Amount'
        $r.error | Should -BeNullOrEmpty
        $r.total | Should -Be 14.75
    }

    It 'handles semicolons, decimal commas, quotes, a BOM and different letter case' {
        $csv = New-Csv 'b.csv' @('"Category";"Amount"', '"groceries";"10,50"', '"Groceries";"4,25"', 'Rent;900') -Bom
        (Read-CsvTotal $csv 'category' 'Groceries' 'amount').total | Should -Be 14.75
    }

    It 'skips cells that are not numbers' {
        $csv = New-Csv 'c.csv' @('Category,Amount', 'Groceries,10', 'Groceries,pending', 'Groceries,')
        (Read-CsvTotal $csv 'Category' 'Groceries' 'Amount').total | Should -Be 10
    }

    It 'reports a missing column and lists the ones it found' {
        $csv = New-Csv 'd.csv' @('Category,Cost', 'Groceries,10')
        $r = Read-CsvTotal $csv 'Category' 'Groceries' 'Amount'
        $r.total | Should -BeNullOrEmpty
        $r.error | Should -Be "Column 'Amount' not found (columns: Category, Cost)"
    }

    It 'reports an empty file' {
        $csv = New-Csv 'e.csv' @()
        (Read-CsvTotal $csv 'Category' 'Groceries' 'Amount').error | Should -Be 'The file is empty'
    }

    It 'reads the shipped sample' {
        $sample = Join-Path $PSScriptRoot '..\..\sample_data\monthly_budget_sample.csv'
        (Read-CsvTotal $sample 'Category' 'Groceries' 'Amount').total | Should -Be 340.15
    }
}

Describe 'Get-DocumentTotal' {
    It 'reports a missing file with the configured path' {
        $r = Get-DocumentTotal ([pscustomobject]@{ path = 'sample_data\nope.csv' })
        $r.error | Should -Be 'File not found: sample_data\nope.csv'
    }

    It 'rejects a file type it cannot read' {
        $file = Join-Path $TestDrive 'notes.json'
        Set-Content $file '{}'
        (Get-DocumentTotal ([pscustomobject]@{ path = $file })).error | Should -Be "Unsupported file type '.json': use .csv or .xlsx"
    }

    It 'reads a CSV without starting Excel' {
        Mock Read-XlsxDocumentTotal { throw 'Excel must not be used for CSV' }
        $csv = New-Csv 'f.csv' @('Category,Amount', 'Groceries,7')
        $doc = [pscustomobject]@{ path = $csv; filter_column = 'Category'; filter_value = 'Groceries'; value_column = 'Amount' }
        (Get-DocumentTotal $doc).total | Should -Be 7
        Should -Invoke Read-XlsxDocumentTotal -Times 0
    }

    It 'sends a workbook to the Excel child process' {
        Mock Read-XlsxDocumentTotal { @{ total = 99; error = $null } }
        $xlsx = Join-Path $TestDrive 'book.xlsx'
        Set-Content $xlsx 'x'
        $doc = [pscustomobject]@{ path = $xlsx; sheet_name = 'Actual'; filter_column = 'Subtype'; filter_value = 'Ebook'; value_column = 'Out' }
        (Get-DocumentTotal $doc).total | Should -Be 99
        Should -Invoke Read-XlsxDocumentTotal -Times 1 -ParameterFilter { $SheetName -eq 'Actual' -and $ValueColumn -eq 'Out' }
    }
}

Describe 'Get-DocumentList' {
    It 'returns every entry of a v1.7 list' {
        $cfg = [pscustomobject]@{ document = @([pscustomobject]@{ display_name = 'A' }, [pscustomobject]@{ display_name = 'B' }) }
        (Get-DocumentList $cfg).display_name | Should -Be @('A', 'B')
    }

    It 'wraps a v1.6 single object, and returns nothing without the section' {
        @(Get-DocumentList ([pscustomobject]@{ document = [pscustomobject]@{ display_name = 'A' } })).Count | Should -Be 1
        @(Get-DocumentList ([pscustomobject]@{ global = @{} })).Count | Should -Be 0
    }
}

Describe 'The file_size measure' {
    BeforeAll {
        $file = Join-Path $TestDrive 'big.log'
        [System.IO.File]::WriteAllBytes($file, (New-Object byte[] (3 * 1024 * 1024 + 512 * 1024)))   # 3.5 MB
    }

    It 'reads the size in <Unit>' -ForEach @(
        @{ Unit = 'KB'; Expected = 3584 }
        @{ Unit = 'MB'; Expected = 3.5 }
        @{ Unit = 'GB'; Expected = 0 }
    ) {
        $r = Get-DocumentTotal ([pscustomobject]@{ measure = 'file_size'; path = $file; size_unit = $Unit })
        $r.error | Should -BeNullOrEmpty
        $r.total | Should -Be $Expected
    }

    It 'defaults to MB' {
        (Get-DocumentTotal ([pscustomobject]@{ measure = 'file_size'; path = $file })).total | Should -Be 3.5
    }

    It 'counts a file that does not exist yet as 0, with a note' {
        $r = Get-DocumentTotal ([pscustomobject]@{ measure = 'file_size'; path = (Join-Path $TestDrive 'later.log') })
        $r.error | Should -BeNullOrEmpty
        $r.total | Should -Be 0
        $r.note  | Should -Match 'not created yet'
    }

    It 'reports a folder as an error' {
        (Get-DocumentTotal ([pscustomobject]@{ measure = 'file_size'; path = $TestDrive })).error | Should -Match 'folder'
    }

    It 'rejects an unknown measure' {
        (Get-DocumentTotal ([pscustomobject]@{ measure = 'rows'; path = $file })).error | Should -Match "Unknown measure 'rows'"
    }

    It 'uses the size unit as {unit}, and sum stays the default measure' {
        $doc = [pscustomobject]@{ display_name = 'Log'; measure = 'file_size'; size_unit = 'KB'; unit = '$'; target = 100
            thresholds = @([pscustomobject]@{ level = 'warning'; condition = 'above'; percent_of_target = 80; actions = @() }) }
        (Get-DocumentChecks $doc 90 (Get-Date) 'pc').Checks[0].Vars.unit | Should -Be 'KB'
        Get-DocumentMeasure ([pscustomobject]@{ path = 'a.csv' }) | Should -Be 'sum'
        Get-DocumentUnit ([pscustomobject]@{ unit = '$' }) | Should -Be '$'
    }
}

Describe 'Get-DocumentChecks' {
    BeforeAll {
        function New-Doc ([string]$Condition) {
            [pscustomobject]@{
                display_name = 'Budget'; target = 400; unit = '$'
                thresholds = @(
                    [pscustomobject]@{ level = 'critical'; condition = $Condition; percent_of_target = 100; actions = @() }
                    [pscustomobject]@{ level = 'warning';  condition = $Condition; percent_of_target = 80;  actions = @() }
                )
            }
        }
        $now = Get-Date '2026-11-13 12:00:00'
    }

    It 'treats "above" as bad when the total grows (a budget)' {
        (Get-DocumentChecks (New-Doc 'above') 300 $now 'pc').Level | Should -Be 'ok'
        (Get-DocumentChecks (New-Doc 'above') 340 $now 'pc').Level | Should -Be 'warning'
        (Get-DocumentChecks (New-Doc 'above') 410 $now 'pc').Level | Should -Be 'critical'
    }

    It 'treats "below" as bad when the total falls short (a sales goal)' {
        $goal = New-Doc 'below'
        $goal.thresholds[0].percent_of_target = 50     # critical: under half the goal
        $goal.thresholds[1].percent_of_target = 100    # warning: goal not reached yet
        (Get-DocumentChecks $goal 420 $now 'pc').Level | Should -Be 'ok'
        (Get-DocumentChecks $goal 360 $now 'pc').Level | Should -Be 'warning'
        (Get-DocumentChecks $goal 150 $now 'pc').Level | Should -Be 'critical'
    }

    It 'orders the checks warning first and fills the template variables' {
        $e = Get-DocumentChecks (New-Doc 'above') 340.15 $now 'pc'
        $e.Percent | Should -Be 85
        $e.Checks.Level | Should -Be @('warning', 'critical')
        $v = $e.Checks[0].Vars
        $v.current_value   | Should -Be '340.15'
        $v.current_percent | Should -Be '85'
        $v.target          | Should -Be '400'
        $v.unit            | Should -Be '$'
        $v.document        | Should -Be 'Budget'
    }

    It 'only recovers once the total is clear_margin points back on the good side' {
        $warn = { param($total) (Get-DocumentChecks (New-Doc 'above') $total $now 'pc').Checks[0] }
        (& $warn 310).BelowClear | Should -BeFalse    # 77.5%: under 80 but within the 5-point margin
        (& $warn 290).BelowClear | Should -BeTrue     # 72.5%
    }

    It 'reports unknown when the target is not positive' {
        $doc = New-Doc 'above'; $doc.target = 0
        (Get-DocumentChecks $doc 10 $now 'pc').Level | Should -Be 'unknown'
    }
}
