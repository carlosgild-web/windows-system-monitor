#Requires -Version 5.1
<#
.SYNOPSIS
    Reads the number the document monitor watches: the sum of one column over the rows
    where another column equals a value (dot-sourced after MonitorCommon.ps1).
.DESCRIPTION
    - .csv (and .txt): read in-process. No Excel needed. Comma or semicolon delimited
      (detected from the header), UTF-8 with or without a BOM.
    - .xlsx / .xlsm / .xls: Excel COM, in a short-lived child process (Read-XlsxTotal.ps1).
      Excel only exits when the process that drove it ends normally, so a long-lived
      monitor must never automate Excel itself.

    Get-DocumentTotal returns @{ total = <double or $null>; error = <string or $null> }.
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

function Get-DocumentTotal ($DocCfg) {
    $rel  = [string]$DocCfg.path
    $path = Resolve-ProjectPath $rel
    if (-not $rel) { return @{ total = $null; error = 'document.path is not set' } }
    if (-not (Test-Path $path)) { return @{ total = $null; error = "File not found: $rel" } }

    $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
    if ($ext -in @('.csv', '.txt')) {
        return Read-CsvTotal $path ([string]$DocCfg.filter_column) ([string]$DocCfg.filter_value) ([string]$DocCfg.value_column)
    }
    if ($ext -in @('.xlsx', '.xlsm', '.xls')) {
        return Read-XlsxDocumentTotal $path ([string]$DocCfg.sheet_name) ([string]$DocCfg.filter_column) `
            ([string]$DocCfg.filter_value) ([string]$DocCfg.value_column)
    }
    return @{ total = $null; error = "Unsupported file type '$ext': use .csv or .xlsx" }
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
    $unit  = if ($null -ne $Doc.unit) { [string]$Doc.unit } else { '' }
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
