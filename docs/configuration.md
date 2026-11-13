# Configuration reference

Everything the monitors do is defined in [`monitoring_settings.json`](../monitoring_settings.json). You can edit it by
hand or with the settings editor (`start_editor.bat`, http://localhost:5757). After a change:

1. Bump `_meta.version` and update `_meta.last_updated`.
2. Run `doctor.bat` to validate it.
3. Restart with `start_monitoring.bat`. Monitors read the file at startup, and the launcher's preflight blocks a
   broken config before stopping the monitors that are already running.

Relative paths (`global.log_file`, `global.scripts_dir`, `ebook_sales.xlsx_path`) are resolved against the project
folder, so the repository works wherever it is cloned.

---

## Top-level shape

```text
{
  "_meta":       { version, last_updated, description, update_notes },
  "global":      { ...defaults shared by every monitor... },
  "processes":   [ ...executables that must be running... ],
  "performance": { "cpu": {...}, "memory": {...} },
  "disk":        [ ...drives... ],
  "network":     [ ...hosts / ports... ],
  "ebook_sales": { ...spreadsheet metric... },
  "others":      { reserved for future monitor types }
}
```

## `global`

| Field | Type | Description |
|---|---|---|
| `check_interval_sec` | number > 0 | Default loop interval. |
| `log_file` | path | Shared log for `log_to_file` actions. The state files are written next to it. |
| `log_max_size_mb` | number > 0 | When the log reaches this size it is renamed with a timestamp and a new one is started. |
| `email_recipient` | string | Available to templates as `{global.email_recipient}`. |
| `email_sender` | string | Informational. |
| `scripts_dir` | path | Available to templates as `{global.scripts_dir}`. |

## `processes[]`

```json
{
  "name": "notepad.exe",
  "display_name": "Notepad",
  "required": true,
  "check_interval_sec": 30,
  "actions": {
    "on_not_running": [
      { "type": "log_to_file", "level": "warning",
        "instructions": "Runbook text shown in the console's 'Perform Actions' dialog" }
    ]
  }
}
```

- `name` must be an executable name (`*.exe`).
- Actions fire when the process goes from running to down. While it stays down they repeat on every check, subject to
  the spam guard (see below). A `RECOVERY` line is logged when it comes back.
- **Process actions use `instructions`, not `message_template`.** The text is shown in the console's runbook dialog
  and in popups. For `log_to_file`, a standard line is written instead of the runbook text:
  `[timestamp] WARNING PROC: Notepad (notepad.exe) not detected.`

## `performance.cpu` / `performance.memory`

```json
"cpu": {
  "check_interval_sec": 5,
  "thresholds": [
    { "level": "warning",  "percent": 80, "sustain_sec": 30, "description": "...", "actions": [ ... ] },
    { "level": "critical", "percent": 95, "sustain_sec": 60, "description": "...", "actions": [ ... ] }
  ]
}
```

A threshold fires only after the value has stayed at or above `percent` for `sustain_sec` seconds. When several
levels are exceeded, only the highest one fires.

## `disk[]`

```json
{ "drive": "C:\\", "display_name": "System Drive (C:)", "check_interval_sec": 60,
  "thresholds": [ { "level": "warning", "percent_used": 75, "actions": [ ... ] } ] }
```

A drive that is not present is reported as `unknown` in the console, and the doctor flags it as a warning.

## `network[]`

```json
{ "name": "Internet Gateway", "host": "8.8.8.8", "port": 53, "protocol": "icmp",
  "timeout_sec": 5, "check_interval_sec": 30,
  "thresholds": [
    { "level": "warning",  "latency_ms": 150,          "actions": [ ... ] },
    { "level": "critical", "condition": "unreachable", "actions": [ ... ] }
  ] }
```

- `protocol` is `icmp` (ping) or `tcp` (TCP connect to `port`, which is required for `tcp`).
- Each threshold needs either `latency_ms` or `"condition": "unreachable"`.

## `ebook_sales`

A business metric read from a spreadsheet. It's included to show that the same pattern works for non-system data.

| Field | Description |
|---|---|
| `xlsx_path` | Workbook path (default: `sample_data\ebook_sales_sample.xlsx`, made-up data). |
| `sheet_name` | Worksheet to read. |
| `subtype_column` / `filter_value` | Rows are included when this column equals this value. |
| `data_column` | Column that is summed. |
| `target_usd` | Goal shown as a progress bar in the console. |
| `check_interval_sec` | Seconds between reads. |

This monitor needs Microsoft Excel (COM automation) and reports progress only; it has no thresholds or actions.

---

## Actions

| Type | What it does | Fields |
|---|---|---|
| `log_to_file` | Appends a line to `global.log_file`. | `level`, `message_template`¹ |
| `popup` | Shows a Windows message box from a separate hidden process, so the monitor never blocks. | `title`, `message_template`¹ |
| `email_draft` | Opens a pre-filled `mailto:` draft in the default mail client. | `to`, `subject_template`, `body_template` |
| `run_script` | Runs a PowerShell script with arguments. | `path`, `args[]` |

¹ Process actions use `instructions` instead of `message_template`.

### Spam guard

The first alert for a condition runs every configured action. While the condition persists, repeat alerts run only
`log_to_file` and `run_script`; `popup` and `email_draft` are suppressed until the condition clears and occurs again.
You get one popup per incident, and the log and remediation keep going.

### Severity convention

| Level | Recommended actions |
|---|---|
| `warning` | `log_to_file`, `popup` |
| `critical` | anything, including `email_draft` and `run_script` |

The doctor warns when a `warning` threshold sends email or runs a script.

### `run_script` handlers

Handlers live in [`scripts/actions/`](../scripts/actions). They are called in-process with GNU-style arguments
taken from `args`, with template variables expanded:

```json
{ "type": "run_script", "path": "{global.scripts_dir}\\actions\\on_disk_critical.ps1",
  "args": ["--drive", "C:", "--value", "{current_value}"] }
```

The samples parse arguments with `ConvertFrom-HandlerArgs` and record the call in the monitor log. Each one
includes a commented example of real remediation. **Keep handlers fast:** they run inside the monitor loop, so
start long-running work with `Start-Process`.

---

## Template variables

| Variable | Available in | Value |
|---|---|---|
| `{timestamp}` | all | `yyyy-MM-dd HH:mm:ss` |
| `{hostname}` | all | Computer name |
| `{global.<field>}` | all | Any field of `global`, e.g. `{global.email_recipient}` |
| `{proc_name}`, `{proc_display}` | processes | Executable and display name |
| `{current_value}` | performance, disk, network | Measured value (%, % used, or ms / `unreachable`) |
| `{percent}`, `{sustain_sec}` | performance | Threshold settings |
| `{percent_used}`, `{free_gb}` | disk | Threshold and current free space |
| `{host}`, `{port}`, `{latency_ms}` | network | Target and latency threshold |

---

## State files

Each monitor writes a JSON state file to `logs/` on every cycle. The console reads them:

| Monitor | File | Main content |
|---|---|---|
| process | `process_state.json` | `processes[]`: `is_running`, `down_since`, `alert_count` |
| performance | `performance_state.json` | `metrics[]`: `current_value`, `current_level` |
| disk | `disk_state.json` | `drives[]`: `percent_used`, `free_gb`, `current_level` |
| network | `network_state.json` | `hosts[]`: `reachable`, `latency_ms`, `current_level` |
| ebook sales | `ebook_state.json` | `total_sales`, `target_usd`, `error` |

Every file has an `updated` timestamp. The console and the doctor treat a monitor as alive only while
`now - updated < 2 × check interval + 15 s`.

## Adding a monitor type

1. Create `scripts/monitor_<type>.ps1`. Mirror an existing monitor: dot-source `lib\MonitorCommon.ps1`, load with
   `Get-MonitorSettings`, dispatch all four action types, and write a state file.
2. Add it to `$MONITORS` in `scripts/start_monitoring.ps1` and to `$MONITOR_SCRIPTS` in `scripts/stop_monitoring.ps1`.
3. Add its section to `monitoring_settings.json` and bump `_meta.version`.
4. Add its state file to `$MonitorDefs` and its schema rules to `Test-DoctorConfig` in `scripts/lib/Doctor.psm1`.
5. Add a render block in `MonitoringConsole/monitoring_console.py`, and a panel in `monitoring_editor.html`.
6. Add Pester cases. The script-quality tests pick up the new file automatically.
