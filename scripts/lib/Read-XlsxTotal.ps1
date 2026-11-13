#Requires -Version 5.1
<#
.SYNOPSIS
    Sums one column of an Excel worksheet for the rows where another column
    equals a filter value, and prints the result as one line of JSON:
        {"total": 359.89, "error": null}
.DESCRIPTION
    Run by the document monitor (DocumentReader.ps1) as a short-lived child process, once per
    read. Excel (COM automation) only exits when the PowerShell process that
    drove it ends normally; doing the read in its own process guarantees that
    no hidden EXCEL.EXE is left behind, even if the monitor is force-stopped.
#>
param(
    [Parameter(Mandatory)] [string]$XlsxFile,
    [Parameter(Mandatory)] [string]$SheetName,
    [Parameter(Mandatory)] [string]$FilterColumn,
    [Parameter(Mandatory)] [string]$DataColumn,
    [Parameter(Mandatory)] [string]$FilterValue
)

$ErrorActionPreference = 'Stop'

function Write-Result ($Total, $ErrorText) {
    [ordered]@{ total = $Total; error = $ErrorText } | ConvertTo-Json -Compress
}

$excel    = $null
$workbook = $null
try {
    $excel               = New-Object -ComObject Excel.Application
    $excel.Visible       = $false
    $excel.DisplayAlerts = $false
    $workbook            = $excel.Workbooks.Open($XlsxFile, $null, $true)

    $sheet = $null
    foreach ($ws in $workbook.Sheets) {
        if ($ws.Name -eq $SheetName) { $sheet = $ws; break }
    }
    if ($null -eq $sheet) {
        Write-Result $null "Sheet '$SheetName' not found"
        return
    }

    $lastRow   = $sheet.UsedRange.Rows.Count
    $lastCol   = $sheet.UsedRange.Columns.Count
    $filterCol = $null
    $dataCol   = $null
    for ($c = 1; $c -le $lastCol; $c++) {
        $header = $sheet.Cells.Item(1, $c).Value2
        if ($header -eq $FilterColumn) { $filterCol = $c }
        if ($header -eq $DataColumn)   { $dataCol   = $c }
    }
    if ($null -eq $filterCol -or $null -eq $dataCol) {
        Write-Result $null "Columns '$FilterColumn'/'$DataColumn' not found in sheet '$SheetName'"
        return
    }

    $total = 0.0
    for ($r = 2; $r -le $lastRow; $r++) {
        if ($sheet.Cells.Item($r, $filterCol).Value2 -eq $FilterValue) {
            $val = $sheet.Cells.Item($r, $dataCol).Value2
            if ($null -ne $val) { $total += [double]$val }
        }
    }
    Write-Result ([math]::Round($total, 2)) $null
}
catch {
    Write-Result $null "Could not read workbook (is Excel installed?): $($_.Exception.Message)"
}
finally {
    if ($null -ne $workbook) { try { $workbook.Close($false) } catch {} }
    if ($null -ne $excel)    { try { $excel.Quit() } catch {} }
    # The process exits right after this, which releases every COM reference.
}
