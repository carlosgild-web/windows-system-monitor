#Requires -Version 5.1
<#
.SYNOPSIS
    Health checks for the monitoring solution, used by doctor.ps1 and by the
    preflight step in start_monitoring.ps1.
.DESCRIPTION
    Every Test-Doctor* function is read-only and returns result objects:
        [pscustomobject]@{ Category; Status = 'OK'|'WARN'|'FAIL'; Check; Detail }
    FAIL means a monitor will crash or an action will never work.
    WARN means something is degraded or unusual but monitoring still runs.
#>

. (Join-Path $PSScriptRoot 'MonitorCommon.ps1')

$ValidActionTypes = @('popup', 'log_to_file', 'email_draft', 'run_script')
$ValidLevels      = @('warning', 'critical')

# Monitor key -> script file and state file (state file name is relative to logs\)
$MonitorDefs = [ordered]@{
    process     = @{ Script = 'process_monitor.ps1';     State = 'process_state.json';     Section = 'processes' }
    performance = @{ Script = 'performance_monitor.ps1'; State = 'performance_state.json'; Section = 'performance' }
    disk        = @{ Script = 'monitor_disk.ps1';        State = 'disk_state.json';        Section = 'disk' }
    network     = @{ Script = 'monitor_network.ps1';     State = 'network_state.json';     Section = 'network' }
    document    = @{ Script = 'monitor_document.ps1';    State = 'document_state.json';    Section = 'document' }
}

# ---- Small helpers -----------------------------------------------------------
function New-DoctorResult ([string]$Category, [string]$Status, [string]$Check, [string]$Detail = '') {
    [pscustomobject]@{ Category = $Category; Status = $Status; Check = $Check; Detail = $Detail }
}

function Test-HasValue ($Object, [string]$Name) {
    return ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name)
}

function Test-IsNumber ($Value) {
    return ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal])
}

function Expand-GlobalTokens ([string]$Text, $GlobalCfg) {
    if ($null -eq $GlobalCfg) { return $Text }
    foreach ($p in $GlobalCfg.PSObject.Properties) {
        $Text = $Text.Replace("{global.$($p.Name)}", [string]$p.Value)
    }
    return $Text
}

# Returns every action list in the config with its location and level, so the
# same rules can be applied to all sections.
function Get-ActionGroups ($Config) {
    $groups = @()
    $i = 0
    foreach ($p in @($Config.processes)) {
        if ($null -eq $p) { continue }
        $acts = if ($p.actions) { $p.actions.on_not_running } else { $null }
        $groups += @{ Where = "processes[$i] ($($p.name))"; Section = 'processes'; Level = $null; Actions = @($acts) }
        $i++
    }
    foreach ($metric in 'cpu', 'memory') {
        $m = if ($Config.performance) { $Config.performance.$metric } else { $null }
        $j = 0
        foreach ($t in @($m.thresholds)) {
            if ($null -eq $t) { continue }
            $groups += @{ Where = "performance.$metric.thresholds[$j]"; Section = 'performance'; Level = $t.level; Actions = @($t.actions) }
            $j++
        }
    }
    foreach ($sec in 'disk', 'network') {
        $k = 0
        foreach ($item in @($Config.$sec)) {
            if ($null -eq $item) { continue }
            $j = 0
            foreach ($t in @($item.thresholds)) {
                if ($null -eq $t) { continue }
                $groups += @{ Where = "$sec[$k].thresholds[$j]"; Section = $sec; Level = $t.level; Actions = @($t.actions) }
                $j++
            }
            $k++
        }
    }
    $j = 0
    foreach ($t in @($Config.document.thresholds)) {
        if ($null -eq $t) { continue }
        $groups += @{ Where = "document.thresholds[$j]"; Section = 'document'; Level = $t.level; Actions = @($t.actions) }
        $j++
    }
    return $groups
}

# ---- Environment ---------------------------------------------------------------
function Test-DoctorEnvironment {
    $r = @()
    $cat = 'Environment'

    $v = $PSVersionTable.PSVersion
    if ($v.Major -ge 5) { $r += New-DoctorResult $cat 'OK' "PowerShell $v" }
    else                { $r += New-DoctorResult $cat 'FAIL' "PowerShell $v" 'Version 5.1 or later is required' }

    foreach ($exe in 'python', 'pythonw') {
        $cmd = Get-Command $exe -ErrorAction SilentlyContinue
        if ($cmd) { $r += New-DoctorResult $cat 'OK' "$exe on PATH" $cmd.Source }
        else      { $r += New-DoctorResult $cat 'FAIL' "$exe on PATH" 'Install Python 3.8+ and tick "Add python.exe to PATH" (needed for the web console and editor)' }
    }

    $ws = Get-Command wscript -ErrorAction SilentlyContinue
    if ($ws) { $r += New-DoctorResult $cat 'OK' 'wscript available' 'used to launch monitors without a window' }
    else     { $r += New-DoctorResult $cat 'FAIL' 'wscript available' 'Windows Script Host is disabled; start_monitoring cannot launch monitors' }

    try {
        $null = Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction Stop
        $r += New-DoctorResult $cat 'OK' 'CPU performance counter readable'
    } catch {
        $r += New-DoctorResult $cat 'WARN' 'CPU performance counter readable' "Get-Counter failed (non-English Windows or disabled counters): $($_.Exception.Message)"
    }
    return $r
}

# ---- Configuration schema ----------------------------------------------------
function Test-ClearSettings ($Threshold, [string]$Where) {
    # Optional hysteresis overrides on any threshold: clear_margin and clear_sec, numbers >= 0.
    foreach ($k in 'clear_margin', 'clear_sec') {
        if ((Test-HasValue $Threshold $k) -and (-not (Test-IsNumber $Threshold.$k) -or $Threshold.$k -lt 0)) {
            New-DoctorResult 'Config' 'FAIL' "$Where.$k" 'Must be a number >= 0'
        }
    }
}

function Test-DoctorConfig ($Config) {
    $r = @()
    $cat = 'Config'
    $errors = 0

    if ($null -eq $Config) { return @(New-DoctorResult $cat 'FAIL' 'Settings loaded' 'No configuration object') }

    if (-not (Test-HasValue $Config._meta 'version')) {
        $r += New-DoctorResult $cat 'WARN' '_meta.version' 'Missing; bump it whenever the file changes'
    }

    # global
    $g = $Config.global
    if ($null -eq $g) {
        $r += New-DoctorResult $cat 'FAIL' 'global section' 'Missing'; $errors++
    } else {
        foreach ($k in 'log_file', 'scripts_dir') {
            if (-not (Test-HasValue $g $k)) { $r += New-DoctorResult $cat 'FAIL' "global.$k" 'Missing'; $errors++ }
        }
        foreach ($k in 'check_interval_sec', 'log_max_size_mb') {
            if (-not (Test-IsNumber $g.$k) -or $g.$k -le 0) { $r += New-DoctorResult $cat 'FAIL' "global.$k" 'Must be a positive number'; $errors++ }
        }
        if ((Test-HasValue $g 'email_cooldown_min') -and (-not (Test-IsNumber $g.email_cooldown_min) -or $g.email_cooldown_min -lt 0)) {
            $r += New-DoctorResult $cat 'FAIL' 'global.email_cooldown_min' 'Must be a number >= 0 (0 turns the cooldown off)'; $errors++
        }
    }

    # processes
    $i = 0
    foreach ($p in @($Config.processes)) {
        if ($null -eq $p) { continue }
        $where = "processes[$i]"
        if (-not (Test-HasValue $p 'name') -or -not ([string]$p.name).EndsWith('.exe')) {
            $r += New-DoctorResult $cat 'FAIL' "$where.name" "'$($p.name)' must be an executable name such as notepad.exe"; $errors++
        }
        if ((Test-HasValue $p 'check_interval_sec') -and (-not (Test-IsNumber $p.check_interval_sec) -or $p.check_interval_sec -le 0)) {
            $r += New-DoctorResult $cat 'FAIL' "$where.check_interval_sec" 'Must be a positive number'; $errors++
        }
        $i++
    }

    # performance
    foreach ($metric in 'cpu', 'memory') {
        $m = if ($Config.performance) { $Config.performance.$metric } else { $null }
        if ($null -eq $m) { continue }
        $j = 0
        foreach ($t in @($m.thresholds)) {
            if ($null -eq $t) { continue }
            $where = "performance.$metric.thresholds[$j]"
            if (-not (Test-IsNumber $t.percent) -or $t.percent -le 0 -or $t.percent -gt 100) {
                $r += New-DoctorResult $cat 'FAIL' "$where.percent" 'Must be a number between 1 and 100'; $errors++
            }
            if (-not (Test-IsNumber $t.sustain_sec) -or $t.sustain_sec -lt 0) {
                $r += New-DoctorResult $cat 'FAIL' "$where.sustain_sec" 'Must be a number >= 0'; $errors++
            }
            $bad = @(Test-ClearSettings $t $where); $r += $bad; $errors += $bad.Count
            $j++
        }
    }

    # disk
    $k = 0
    foreach ($d in @($Config.disk)) {
        if ($null -eq $d) { continue }
        if (-not ([string]$d.drive -match '^[A-Za-z]:\\?$')) {
            $r += New-DoctorResult $cat 'FAIL' "disk[$k].drive" "'$($d.drive)' must look like C:\"; $errors++
        }
        $j = 0
        foreach ($t in @($d.thresholds)) {
            if ($null -eq $t) { continue }
            if (-not (Test-IsNumber $t.percent_used) -or $t.percent_used -le 0 -or $t.percent_used -gt 100) {
                $r += New-DoctorResult $cat 'FAIL' "disk[$k].thresholds[$j].percent_used" 'Must be a number between 1 and 100'; $errors++
            }
            $bad = @(Test-ClearSettings $t "disk[$k].thresholds[$j]"); $r += $bad; $errors += $bad.Count
            $j++
        }
        $k++
    }

    # network
    $k = 0
    foreach ($n in @($Config.network)) {
        if ($null -eq $n) { continue }
        $where = "network[$k]"
        if (-not (Test-HasValue $n 'host')) { $r += New-DoctorResult $cat 'FAIL' "$where.host" 'Missing'; $errors++ }
        if ($n.protocol -notin @('icmp', 'tcp')) {
            $r += New-DoctorResult $cat 'FAIL' "$where.protocol" "'$($n.protocol)' must be icmp or tcp"; $errors++
        }
        if ($n.protocol -eq 'tcp' -and (-not (Test-IsNumber $n.port) -or $n.port -lt 1 -or $n.port -gt 65535)) {
            $r += New-DoctorResult $cat 'FAIL' "$where.port" 'TCP checks need a port between 1 and 65535'; $errors++
        }
        $j = 0
        foreach ($t in @($n.thresholds)) {
            if ($null -eq $t) { continue }
            $hasLatency = Test-IsNumber $t.latency_ms
            $isDown     = $t.condition -eq 'unreachable'
            if (-not $hasLatency -and -not $isDown) {
                $r += New-DoctorResult $cat 'FAIL' "$where.thresholds[$j]" 'Needs latency_ms or condition "unreachable"'; $errors++
            }
            $bad = @(Test-ClearSettings $t "$where.thresholds[$j]"); $r += $bad; $errors += $bad.Count
            $j++
        }
        $k++
    }

    # document
    $doc = $Config.document
    if ($null -ne $doc) {
        foreach ($f in 'path', 'filter_column', 'filter_value', 'value_column') {
            if (-not (Test-HasValue $doc $f)) { $r += New-DoctorResult $cat 'FAIL' "document.$f" 'Missing'; $errors++ }
        }
        if (-not (Test-IsNumber $doc.target) -or $doc.target -le 0) {
            $r += New-DoctorResult $cat 'FAIL' 'document.target' 'Must be a positive number'; $errors++
        }
        if ([string]$doc.path -match '\.xls[xm]?$' -and -not (Test-HasValue $doc 'sheet_name')) {
            $r += New-DoctorResult $cat 'FAIL' 'document.sheet_name' 'Excel documents need the worksheet name'; $errors++
        }
        if ((Test-HasValue $doc 'check_interval_sec') -and (-not (Test-IsNumber $doc.check_interval_sec) -or $doc.check_interval_sec -le 0)) {
            $r += New-DoctorResult $cat 'FAIL' 'document.check_interval_sec' 'Must be a positive number'; $errors++
        }
        $j = 0
        foreach ($t in @($doc.thresholds)) {
            if ($null -eq $t) { continue }
            $where = "document.thresholds[$j]"
            if (-not (Test-IsNumber $t.percent_of_target) -or $t.percent_of_target -le 0) {
                $r += New-DoctorResult $cat 'FAIL' "$where.percent_of_target" 'Must be a positive number (percent of document.target)'; $errors++
            }
            if ($t.condition -notin @('above', 'below')) {
                $r += New-DoctorResult $cat 'FAIL' "$where.condition" "'$($t.condition)' must be above or below"; $errors++
            }
            $bad = @(Test-ClearSettings $t $where); $r += $bad; $errors += $bad.Count
            $j++
        }
    }
    if ($null -ne $Config.ebook_sales) {
        $r += New-DoctorResult $cat 'WARN' 'ebook_sales' 'Replaced by the "document" section in v1.6.0 and ignored; see docs/configuration.md'
    }

    # actions (all sections)
    foreach ($grp in Get-ActionGroups $Config) {
        if ($null -ne $grp.Level -and $grp.Level -notin $ValidLevels) {
            $r += New-DoctorResult $cat 'FAIL' "$($grp.Where).level" "'$($grp.Level)' must be warning or critical"; $errors++
        }
        $a = 0
        foreach ($act in $grp.Actions) {
            if ($null -eq $act) { continue }
            $where = "$($grp.Where).actions[$a]"
            $type  = [string]$act.type
            if ($type -notin $ValidActionTypes) {
                $r += New-DoctorResult $cat 'FAIL' "$where.type" "'$type' is not one of: $($ValidActionTypes -join ', ')"; $errors++
            } else {
                # Text field: processes use 'instructions', other sections 'message_template'.
                if ($type -in @('popup', 'log_to_file')) {
                    $want  = if ($grp.Section -eq 'processes') { 'instructions' } else { 'message_template' }
                    $other = if ($want -eq 'instructions') { 'message_template' } else { 'instructions' }
                    if (-not (Test-HasValue $act $want)) {
                        $status = if (Test-HasValue $act $other) { 'WARN' } else { 'FAIL' }
                        $detail = if ($status -eq 'WARN') { "Uses '$other'; $($grp.Section) actions should use '$want'" } else { "Missing '$want'" }
                        $r += New-DoctorResult $cat $status "$where ($type)" $detail
                        if ($status -eq 'FAIL') { $errors++ }
                    }
                }
                if ($type -eq 'run_script' -and -not (Test-HasValue $act 'path')) {
                    $r += New-DoctorResult $cat 'FAIL' "$where (run_script)" "Missing 'path'"; $errors++
                }
                if ($type -eq 'email_draft') {
                    foreach ($f in 'to', 'subject_template', 'body_template') {
                        if (-not (Test-HasValue $act $f)) { $r += New-DoctorResult $cat 'FAIL' "$where (email_draft)" "Missing '$f'"; $errors++ }
                    }
                }
                if ($grp.Level -eq 'warning' -and $type -in @('email_draft', 'run_script')) {
                    $r += New-DoctorResult $cat 'WARN' "$where ($type)" 'By convention only critical thresholds send email or run scripts'
                }
            }
            $a++
        }
    }

    if ($errors -eq 0) { $r = @(New-DoctorResult $cat 'OK' 'Schema valid' 'All sections, thresholds and actions are well-formed') + $r }
    return $r
}

# ---- Paths -------------------------------------------------------------------
function Test-DoctorPaths ($Config) {
    $r = @()
    $cat = 'Paths'
    $g = $Config.global

    $logDir = Split-Path ([string]$g.log_file) -Parent
    if ($logDir -and (Test-Path $logDir)) {
        $r += New-DoctorResult $cat 'OK' 'Log folder' $logDir
    } elseif ($logDir -and (Test-Path (Split-Path $logDir -Parent))) {
        $r += New-DoctorResult $cat 'WARN' 'Log folder' "$logDir does not exist yet (created on first write)"
    } else {
        $r += New-DoctorResult $cat 'FAIL' 'Log folder' "Cannot create $logDir; fix global.log_file"
    }

    if ($g.log_file -and (Test-Path $g.log_file)) {
        $sizeMb = [math]::Round((Get-Item $g.log_file).Length / 1MB, 1)
        $status = if ($sizeMb -ge [double]$g.log_max_size_mb) { 'WARN' } else { 'OK' }
        $r += New-DoctorResult $cat $status 'Log size' "$sizeMb MB of $($g.log_max_size_mb) MB (rotated at the limit)"
    }

    if ($g.scripts_dir -and (Test-Path $g.scripts_dir)) { $r += New-DoctorResult $cat 'OK' 'Scripts folder' $g.scripts_dir }
    else { $r += New-DoctorResult $cat 'FAIL' 'Scripts folder' "Not found: $($g.scripts_dir)" }

    # run_script targets
    $seen = @{}
    foreach ($grp in Get-ActionGroups $Config) {
        foreach ($act in $grp.Actions) {
            if ($null -eq $act -or $act.type -ne 'run_script' -or -not $act.path) { continue }
            $path = Expand-GlobalTokens ([string]$act.path) $g
            if ($seen.ContainsKey($path)) { continue }
            $seen[$path] = $true
            $name = Split-Path $path -Leaf
            if (Test-Path $path) { $r += New-DoctorResult $cat 'OK' "run_script $name" $grp.Where }
            else { $r += New-DoctorResult $cat 'FAIL' "run_script $name" "Not found: $path (action is silently skipped)" }
        }
    }

    # document file (+ Excel, only when it is a workbook)
    $doc = $Config.document
    if ($null -ne $doc -and $doc.path) {
        $file = Resolve-ProjectPath ([string]$doc.path)
        if (Test-Path $file) { $r += New-DoctorResult $cat 'OK' 'Document file' $doc.path }
        else { $r += New-DoctorResult $cat 'FAIL' 'Document file' "Not found: $file" }
        if ([string]$doc.path -match '\.xls[xm]?$') {
            if (Test-Path 'Registry::HKEY_CLASSES_ROOT\Excel.Application') {
                $r += New-DoctorResult $cat 'OK' 'Excel COM registered' 'needed to read the .xlsx document'
            } else {
                $r += New-DoctorResult $cat 'WARN' 'Excel COM registered' 'Microsoft Excel not found; use a .csv document or install Excel'
            }
        }
    }

    # drives
    $present = @(Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue | ForEach-Object { $_.DeviceID })
    foreach ($d in @($Config.disk)) {
        if ($null -eq $d) { continue }
        $id = ([string]$d.drive).TrimEnd('\')
        if ($present -contains $id) { $r += New-DoctorResult $cat 'OK' "Drive $id" 'present' }
        else { $r += New-DoctorResult $cat 'WARN' "Drive $id" 'Not present; it will show as unknown in the console' }
    }
    return $r
}

# ---- Runtime -----------------------------------------------------------------
function Get-MaxInterval ($Config, [string]$Section) {
    $vals = @([double]$Config.global.check_interval_sec)
    $s = $Config.$Section
    if ($Section -eq 'performance' -and $s) { $vals += @($s.cpu.check_interval_sec, $s.memory.check_interval_sec) }
    elseif ($s) { $vals += @($s | ForEach-Object { $_.check_interval_sec }) }
    $nums = @($vals | Where-Object { Test-IsNumber $_ } | ForEach-Object { [double]$_ })
    return ($nums | Measure-Object -Maximum).Maximum
}

function Test-DoctorRuntime ($Config) {
    $r = @()
    $cat = 'Runtime'
    $procs  = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'power*' -or $_.Name -like 'python*' })
    $logDir = Split-Path ([string]$Config.global.log_file) -Parent
    $now    = Get-Date
    $running = 0

    foreach ($key in $MonitorDefs.Keys) {
        $def = $MonitorDefs[$key]
        if ($null -eq $Config.($def.Section)) { continue }
        $stem  = [System.IO.Path]::GetFileNameWithoutExtension($def.Script)
        $alive = @($procs | Where-Object { $_.Name -like 'power*' -and $_.CommandLine -like "*$stem*" })
        $stateFile = if ($key -eq 'process') { Join-Path $MonitorProjectRoot "logs\$($def.State)" } else { Join-Path $logDir $def.State }

        if ($alive.Count -eq 0) {
            $r += New-DoctorResult $cat 'WARN' "$key monitor" 'Not running (start it with start_monitoring.bat)'
            continue
        }
        $running++
        if ($alive.Count -gt 1) {
            $r += New-DoctorResult $cat 'WARN' "$key monitor" "$($alive.Count) instances running; run stop_monitoring.bat then start again"
            continue
        }
        if (-not (Test-Path $stateFile)) {
            $r += New-DoctorResult $cat 'WARN' "$key monitor" "Running (PID $($alive[0].ProcessId)) but no state file yet"
            continue
        }
        # Clamp: a file written just after $now was taken would show a negative age.
        $age   = [math]::Max(0, ($now - (Get-Item $stateFile).LastWriteTime).TotalSeconds)
        $limit = 2 * (Get-MaxInterval $Config $def.Section) + 15
        if ($age -le $limit) {
            $r += New-DoctorResult $cat 'OK' "$key monitor" ("PID {0}, state updated {1:N0}s ago" -f $alive[0].ProcessId, $age)
        } else {
            $r += New-DoctorResult $cat 'FAIL' "$key monitor" ("Running but state file is {0:N0}s old (limit {1:N0}s): the monitor loop is stuck" -f $age, $limit)
        }
    }

    foreach ($port in 5758, 5757) {
        $name = if ($port -eq 5758) { 'Console port 5758' } else { 'Editor port 5757' }
        $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $conn) {
            $status = if ($port -eq 5758 -and $running -gt 0) { 'WARN' } else { 'OK' }
            $detail = if ($status -eq 'WARN') { 'Monitors are running but the console is not' } else { 'free' }
            $r += New-DoctorResult $cat $status $name $detail
            continue
        }
        $owner = Get-CimInstance Win32_Process -Filter "ProcessId=$($conn.OwningProcess)" -ErrorAction SilentlyContinue
        $ours  = $owner -and $owner.CommandLine -match 'monitoring_console|server\.py'
        if ($ours) { $r += New-DoctorResult $cat 'OK' $name "in use by this project (PID $($conn.OwningProcess))" }
        else       { $r += New-DoctorResult $cat 'FAIL' $name "Taken by another program: $($owner.Name) (PID $($conn.OwningProcess))" }
    }
    return $r
}

# ---- Orchestration -----------------------------------------------------------
function Invoke-Doctor ([string]$SettingsPath, [switch]$SkipRuntime, [switch]$SkipEnvironment) {
    if (-not $SettingsPath) { $SettingsPath = Join-Path $MonitorProjectRoot 'monitoring_settings.json' }
    $results = @()
    if (-not $SkipEnvironment) { $results += Test-DoctorEnvironment }
    try {
        $cfg = Get-MonitorSettings $SettingsPath
        $results += New-DoctorResult 'Config' 'OK' 'Settings file parses' $SettingsPath
    } catch {
        $results += New-DoctorResult 'Config' 'FAIL' 'Settings file parses' $_.Exception.Message
        return $results
    }
    $results += Test-DoctorConfig $cfg
    $results += Test-DoctorPaths  $cfg
    if (-not $SkipRuntime) { $results += Test-DoctorRuntime $cfg }
    return $results
}

function Write-DoctorReport ($Results) {
    $colors = @{ OK = 'Green'; WARN = 'Yellow'; FAIL = 'Red' }
    foreach ($group in ($Results | Group-Object Category)) {
        Write-Host ''
        Write-Host "  $($group.Name)" -ForegroundColor Cyan
        foreach ($res in $group.Group) {
            $tag = '[{0,-4}]' -f $res.Status
            Write-Host ("    $tag ") -ForegroundColor $colors[$res.Status] -NoNewline
            Write-Host $res.Check -NoNewline
            if ($res.Detail) { Write-Host "  -  $($res.Detail)" -ForegroundColor DarkGray } else { Write-Host '' }
        }
    }
}

Export-ModuleMember -Function Test-DoctorEnvironment, Test-DoctorConfig, Test-DoctorPaths, Test-DoctorRuntime,
                              Invoke-Doctor, Write-DoctorReport, Get-MonitorSettings, Resolve-ProjectPath
