$ErrorActionPreference = 'Continue'

# Get-MonitorSettings / Resolve-ProjectPath
. (Join-Path $PSScriptRoot 'lib\MonitorCommon.ps1')

$ProjectRoot  = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent
$SettingsFile = Join-Path $ProjectRoot "monitoring_settings.json"
$StateFile    = Join-Path $ProjectRoot "logs\ebook_state.json"
$ReaderScript = Join-Path $PSScriptRoot 'lib\Read-XlsxTotal.ps1'

# Each read runs in a short-lived child PowerShell. Excel only exits when the
# process that drove it ends normally, so reading in-process would leave a
# hidden EXCEL.EXE behind whenever this long-lived monitor is force-stopped.
function Get-EbookTotal($XlsxFile, $sheetName, $subtypeHdr, $dataHdr, $filterVal) {
    $json = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ReaderScript `
        -XlsxFile $XlsxFile -SheetName $sheetName -FilterColumn $subtypeHdr `
        -DataColumn $dataHdr -FilterValue $filterVal
    $line = @($json | Where-Object { $_ -match '^\s*\{' }) | Select-Object -Last 1
    if (-not $line) { return @{ total = $null; error = 'Workbook reader returned no result' } }
    return ($line | ConvertFrom-Json)
}

while ($true) {
    try {
        $cfg         = Get-MonitorSettings $SettingsFile
        $ebookCfg    = $cfg.ebook_sales
        $targetUsd   = if ($null -ne $ebookCfg -and $null -ne $ebookCfg.target_usd)        { [double]$ebookCfg.target_usd }        else { 300.0 }
        $checkSec    = if ($null -ne $ebookCfg -and $null -ne $ebookCfg.check_interval_sec) { [int]$ebookCfg.check_interval_sec }    else { 60 }
        $displayName = if ($null -ne $ebookCfg -and $null -ne $ebookCfg.display_name)       { [string]$ebookCfg.display_name }       else { "Total Ebook Sales" }
        $xlsxRel     = if ($null -ne $ebookCfg -and $null -ne $ebookCfg.xlsx_path)          { [string]$ebookCfg.xlsx_path }          else { "sample_data\ebook_sales_sample.xlsx" }
        $sheetName   = if ($null -ne $ebookCfg -and $null -ne $ebookCfg.sheet_name)         { [string]$ebookCfg.sheet_name }         else { "Actual" }
        $subtypeHdr  = if ($null -ne $ebookCfg -and $null -ne $ebookCfg.subtype_column)     { [string]$ebookCfg.subtype_column }     else { "Subtype" }
        $dataHdr     = if ($null -ne $ebookCfg -and $null -ne $ebookCfg.data_column)        { [string]$ebookCfg.data_column }        else { "Out" }
        $filterVal   = if ($null -ne $ebookCfg -and $null -ne $ebookCfg.filter_value)       { [string]$ebookCfg.filter_value }       else { "Ebook" }
        $XlsxFile    = Resolve-ProjectPath $xlsxRel

        $errorMsg = $null
        $total    = $null
        if (-not (Test-Path $XlsxFile)) {
            $errorMsg = "File not found: $xlsxRel"
        } else {
            $result   = Get-EbookTotal $XlsxFile $sheetName $subtypeHdr $dataHdr $filterVal
            $total    = $result.total
            $errorMsg = $result.error
        }
        $ts    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        if ($null -ne $total) {
            $state = [ordered]@{
                updated      = $ts
                display_name = $displayName
                total_sales  = $total
                target_usd   = $targetUsd
                filter_value = $filterVal
            }
        } else {
            $state = [ordered]@{
                updated      = $ts
                display_name = $displayName
                total_sales  = 0.0
                target_usd   = $targetUsd
                filter_value = $filterVal
                error        = $errorMsg
            }
        }

        $logsDir = Join-Path $ProjectRoot "logs"
        if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
        $state | ConvertTo-Json -Depth 3 | Set-Content -Path $StateFile -Encoding UTF8
    }
    catch {
        # Silent — keep the loop alive
    }

    Start-Sleep -Seconds $checkSec
}
