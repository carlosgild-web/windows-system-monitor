#Requires -Version 5.1
<#
.SYNOPSIS
    Reads the number the document monitor watches: the sum of one column over the rows
    where another column equals a value, or the file's size (dot-sourced after MonitorCommon.ps1).
.DESCRIPTION
    - .csv (and .txt): read in-process. No Excel needed. Comma or semicolon delimited
      (detected from the header), UTF-8 with or without a BOM.
    - .xlsx / .xlsm / .xls: Excel COM, in a short-lived child process (Read-XlsxTotal.ps1).
      Excel only exits when the process that drove it ends normally, so a long-lived
      monitor must never automate Excel itself.

    - measure "file_size": the file's size in size_unit (KB, MB or GB; default MB). A file
      that does not exist yet counts as 0, so "above" thresholds stay quiet and "below"
      thresholds fire.

    Get-DocumentList returns the "document" section as a list (a v1.6 single object too).
    Get-DocumentTotal returns @{ total = <double or $null>; error = <string or $null>; note }.
    Get-DocumentChecks turns a total into the threshold checks for Invoke-ThresholdAlerts.
#>

function ConvertTo-DocumentNumber ([string]$Text) {
    # '342.65', '$1,234.50', '12,5' (decimal comma), '-8' -> double; $null when not a number.
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text -replace '[^0-9,.\-]', ''
    if ($t -match ',' -and $t -match '\.') { $t = $t -replace ',', '' }   # thousands separator
    elseif ($t -match ',')                 { $t = $t -replace ',', '.' }  # decimal comma
    $n = 0.0
    $ok = [double]::TryParse($t, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)
    if ($ok) { return $n }
    return $null
}

function Read-CsvTotal ([string]$Path, [string]$FilterColumn, [string]$FilterValue, [string]$ValueColumn) {
    try {
        $lines = @(Get-Content -Path $Path -Encoding UTF8 -ErrorAction Stop | Where-Object { $_.Trim() -ne '' })
        if ($lines.Count -eq 0) { return @{ total = $null; error = 'The file is empty' } }

        $header = $lines[0]
        $delim  = if ($header.Split(';').Count -gt $header.Split(',').Count) { ';' } else { ',' }
        $names  = @($header.Split($delim) | ForEach-Object { $_.Trim().Trim('"') })
        foreach ($col in $FilterColumn, $ValueColumn) {
            if ($names -notcontains $col) {
                return @{ total = $null; error = "Column '$col' not found (columns: $($names -join ', '))" }
            }
        }

        $total = 0.0
        foreach ($row in ($lines | ConvertFrom-Csv -Delimiter $delim)) {
            if (([string]$row.$FilterColumn).Trim() -ne $FilterValue) { continue }
            $n = ConvertTo-DocumentNumber ([string]$row.$ValueColumn)
            if ($null -ne $n) { $total += $n }
        }
        return @{ total = [math]::Round($total, 2); error = $null }
    }
    catch {
        return @{ total = $null; error = "Could not read the CSV file: $($_.Exception.Message)" }
    }
}

function Read-XlsxDocumentTotal ([string]$Path, [string]$SheetName, [string]$FilterColumn, [string]$FilterValue, [string]$ValueColumn) {
    $reader = Join-Path $PSScriptRoot 'Read-XlsxTotal.ps1'
    $out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $reader `
        -XlsxFile $Path -SheetName $SheetName -FilterColumn $FilterColumn -DataColumn $ValueColumn -FilterValue $FilterValue
    $line = @($out | Where-Object { $_ -match '^\s*\{' }) | Select-Object -Last 1
    if (-not $line) { return @{ total = $null; error = 'The workbook reader returned no result' } }
    $r = $line | ConvertFrom-Json
    return @{ total = $r.total; error = $r.error }
}

function Get-DocumentList ($Config) {
    # "document" is a list since v1.7; a v1.6 single object is still accepted.
    return @(@($Config.document) | Where-Object { $null -ne $_ })
}

function Get-DocumentMeasure ($DocCfg) {
    $m = [string]$DocCfg.measure
    if ([string]::IsNullOrWhiteSpace($m)) { return 'sum' }
    return $m.ToLowerInvariant()
}

function Get-DocumentSizeUnit ($DocCfg) {
    $u = ([string]$DocCfg.size_unit).ToUpperInvariant()
    if ($u -in @('KB', 'MB', 'GB')) { return $u }
    return 'MB'
}

function Get-DocumentFileSize ([string]$Path, [string]$SizeUnit = 'MB') {
    # Size of a file in KB, MB or GB, rounded to 2 places. A file that is not there yet is 0.
    $divisor = switch ($SizeUnit) { 'KB' { 1KB } 'GB' { 1GB } default { 1MB } }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        if (Test-Path -LiteralPath $Path) { return @{ total = $null; error = 'The path is a folder, not a file'; note = $null } }
        return @{ total = 0.0; error = $null; note = 'File not created yet: counted as 0' }
    }
    try {
        $bytes = (Get-Item -LiteralPath $Path -ErrorAction Stop).Length
        return @{ total = [math]::Round($bytes / $divisor, 2); error = $null; note = $null }
    }
    catch {
        return @{ total = $null; error = "Could not read the file size: $($_.Exception.Message)"; note = $null }
    }
}

function Get-DocumentTotal ($DocCfg) {
    $rel  = [string]$DocCfg.path
    if (-not $rel) { return @{ total = $null; error = 'document.path is not set'; note = $null } }
    $path = Resolve-ProjectPath $rel

    $measure = Get-DocumentMeasure $DocCfg
    if ($measure -eq 'file_size') { return Get-DocumentFileSize $path (Get-DocumentSizeUnit $DocCfg) }
    if ($measure -ne 'sum') { return @{ total = $null; error = "Unknown measure '$measure': use sum or file_size"; note = $null } }

    if (-not (Test-Path $path)) { return @{ total = $null; error = "File not found: $rel"; note = $null } }
    $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
    $r = $null
    if ($ext -in @('.csv', '.txt')) {
        $r = Read-CsvTotal $path ([string]$DocCfg.filter_column) ([string]$DocCfg.filter_value) ([string]$DocCfg.value_column)
    } elseif ($ext -in @('.xlsx', '.xlsm', '.xls')) {
        $r = Read-XlsxDocumentTotal $path ([string]$DocCfg.sheet_name) ([string]$DocCfg.filter_column) `
            ([string]$DocCfg.filter_value) ([string]$DocCfg.value_column)
    } else {
        return @{ total = $null; error = "Unsupported file type '$ext': use .csv or .xlsx"; note = $null }
    }
    return @{ total = $r.total; error = $r.error; note = $null }
}

function Get-DocumentUnit ($DocCfg) {
    # The unit shown with values and in {unit}: the size unit for file_size, else document.unit.
    if ((Get-DocumentMeasure $DocCfg) -eq 'file_size') { return Get-DocumentSizeUnit $DocCfg }
    if ($null -ne $DocCfg.unit) { return [string]$DocCfg.unit }
    return ''
}

function Get-DocumentChecks ($Doc, [double]$Total, [datetime]$Now, [string]$Hostname) {
    # Returns @{ Percent; Level; Checks }. Each threshold compares the total, as a percent of
    # document.target, with percent_of_target: "above" for a spend or an error count, "below"
    # for a sales goal or a stock level. Hysteresis: the incident closes once the percent is
    # clear_margin points (default 5) back on the good side, for clear_sec (default 0: the
    # file changes only when someone saves it).
    $inv    = [Globalization.CultureInfo]::InvariantCulture
    $target = [double]$Doc.target
    if ($target -le 0) { return @{ Percent = $null; Level = 'unknown'; Checks = @() } }
    $pct   = [math]::Round($Total / $target * 100, 1)
    $level = 'ok'
    $name  = if ($Doc.display_name) { [string]$Doc.display_name } else { 'Document' }
    $unit  = Get-DocumentUnit $Doc
    $checks = foreach ($t in (Get-ThresholdsLowFirst $Doc.thresholds)) {
        if ($null -eq $t.percent_of_target) { continue }
        $limit  = [double]$t.percent_of_target
        $margin = Get-ClearSetting $t 'clear_margin' 5
        if ($t.condition -eq 'below') {
            $exceeded  = $pct -lt $limit
            $recovered = $pct -ge ($limit + $margin)
        } else {
            $exceeded  = $pct -ge $limit
            $recovered = $pct -lt ($limit - $margin)
        }
        if ($exceeded) { $level = $t.level }
        @{
            Level      = $t.level
            Actions    = $t.actions
            Exceeded   = $exceeded
            BelowClear = $recovered
            SustainSec = 0
            ClearSec   = (Get-ClearSetting $t 'clear_sec' 0)
            Vars       = @{
                timestamp         = $Now.ToString('yyyy-MM-dd HH:mm:ss')
                hostname          = $Hostname
                document          = $name
                current_value     = $Total.ToString('0.00', $inv)
                current_percent   = $pct.ToString('0.#', $inv)
                target            = $target.ToString('0.##', $inv)
                unit              = $unit
                percent_of_target = [string]$t.percent_of_target
            }
        }
    }
    return @{ Percent = $pct; Level = $level; Checks = @($checks) }
}
