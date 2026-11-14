# Configuration reference

Everything the monitors do is defined in [`monitoring_settings.json`](../monitoring_settings.json). You can edit it by
hand or with the settings editor (`start_editor.bat`, http://localhost:5757). After a change:

1. Bump `_meta.version` and update `_meta.last_updated`.
2. Run `doctor.bat` to validate it.
3. Restart with `start_monitoring.bat`. Monitors read the file at startup, and the launcher's preflight blocks a
   broken config before stopping the monitors that are already running.

Relative paths (`global.log_file`, `global.scripts_dir`, each `document[].path`) are resolved against the project
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
  "document":    [ ...a total in a CSV / Excel file, or a file's size... ],
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
| `email_cooldown_min` | number >= 0 | At most one `email_draft` per item and level within this many minutes (default 60, `0` = off). See [Incidents, spam guard and email cooldown](#incidents-spam-guard-and-email-cooldown). |
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
levels are exceeded, only the highest one fires. The incident then stays open until the value has been below
`percent - clear_margin` for `clear_sec` (see [Incidents](#incidents-spam-guard-and-email-cooldown)).

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

## `document`

A list of documents, each watched like a metric. A document's number is either:

- `"measure": "sum"` (the default): the sum of `value_column` over the rows where `filter_column` equals
  `filter_value` in a CSV or Excel file. This shows that the same thresholds and actions work for business data,
  not just system metrics.
- `"measure": "file_size"`: the file's size in `size_unit`, for a log, an export or a report that must not grow too
  big (or must reach a minimum size).

Either way the number is compared with `target`. The defaults watch two lines of a made-up monthly budget and the
size of the monitors' own log:

```json
"document": [
  {
    "display_name": "Groceries spend (monthly budget)",
    "measure": "sum",
    "path": "sample_data\\monthly_budget_sample.csv",
    "filter_column": "Category", "filter_value": "Groceries", "value_column": "Amount",
    "target": 400, "unit": "$", "check_interval_sec": 30,
    "thresholds": [
      { "level": "warning",  "condition": "above", "percent_of_target": 80,  "actions": [ ... ] },
      { "level": "critical", "condition": "above", "percent_of_target": 100, "actions": [ ... ] }
    ]
  },
  {
    "display_name": "Monitor log size",
    "measure": "file_size",
    "path": "logs\\monitor.log",
    "size_unit": "MB", "target": 50, "check_interval_sec": 60,
    "thresholds": [
      { "level": "warning",  "condition": "above", "percent_of_target": 80, "actions": [ ... ] },
      { "level": "critical", "condition": "above", "percent_of_target": 95, "actions": [ ... ] }
    ]
  }
]
```

| Field | Applies to | Description |
|---|---|---|
| `display_name` | all | Shown in the console and in `{document}`. **Must be unique**: it keys alerts and console rows (the doctor checks). |
| `measure` | all | `sum` (default when missing) or `file_size`. |
| `path` | all | Relative to the project folder. `sum`: `.csv` (no Excel needed) or `.xlsx`/`.xlsm` (needs Microsoft Excel). `file_size`: any file. |
| `sheet_name` | sum | Worksheet to read. Excel files only. |
| `filter_column` / `filter_value` | sum | Rows are included when this column equals this value (not case-sensitive). |
| `value_column` | sum | Column that is summed. Cells that are not numbers are skipped. |
| `unit` | sum | Optional text shown before values, such as `$`. |
| `size_unit` | file_size | `KB`, `MB` (default) or `GB`. `target` is in this unit, and so are `{current_value}` and `{unit}`. |
| `target` | all | The 100 % mark for `percent_of_target`. |
| `check_interval_sec` | all | Seconds between reads. Settings are re-read every pass, so adding a document or changing one applies without a restart. |

**Thresholds** use `percent_of_target` and a `condition`:

- `"above"`: bad when the number grows (a spend, an error count, a file size). Fires at `value >= percent_of_target % of target`.
- `"below"`: bad when the number falls short (a sales goal, a stock level, an export that must not be empty). Fires at `value < percent_of_target % of target`.

The incident closes once the value is `clear_margin` points (default 5) back on the good side, after `clear_sec`
(default 0, because a file only changes when someone saves it).

**File size and missing files**: a `file_size` document whose file does not exist yet counts as 0, with a note in
the console. So `above` thresholds stay quiet (a log that has not been written yet is not too big) and `below`
thresholds fire (an export that never arrived is a problem). The doctor reports such a file as a warning, not a
failure. A missing file with `sum` is an error, since there is nothing to add up. A folder is always an error.

**CSV files**: comma or semicolon delimited (detected from the header), UTF-8 with or without a BOM. Numbers may use
a decimal point (`1,234.50`) or a decimal comma (`12,50`).

**Excel files** are read through Excel COM in a short-lived child process (`scripts/lib/Read-XlsxTotal.ps1`), which is
slow (seconds per read) and needs Office. `file_size` never opens Excel, whatever the file type. The made-up
`sample_data/ebook_sales_sample.xlsx` works with `"sheet_name": "Actual"`, `"filter_column": "Subtype"`,
`"filter_value": "Ebook"`, `"value_column": "Out"` and a `"below"` threshold, like the v1.5 Ebook Sales monitor.

> **Upgrading from v1.6:** `document` was a single object. It is now a list, but a single object is still accepted
> everywhere (monitor, console, editor, doctor, simulator) and is treated as a one-item list. The editor saves it
> back as a list.
>
> **Upgrading from v1.5:** the `ebook_sales` section is replaced by `document` and is ignored (the doctor warns).
> `xlsx_path` → `path`, `subtype_column` → `filter_column`, `data_column` → `value_column`, `target_usd` → `target`.

---

## Actions

| Type | What it does | Fields |
|---|---|---|
| `log_to_file` | Appends a line to `global.log_file`. | `level`, `message_template`¹ |
| `popup` | Shows a Windows message box from a separate hidden process, so the monitor never blocks. | `title`, `message_template`¹ |
| `email_draft` | Opens a pre-filled `mailto:` draft in the default mail client. | `to`, `subject_template`, `body_template` |
| `run_script` | Runs a PowerShell script with arguments. | `path`, `args[]` |

¹ Process actions use `instructions` instead of `message_template`.

### Incidents, spam guard and email cooldown

Three rules keep a noisy metric from flooding you with popups and email drafts.

**1. One incident per problem (hysteresis).** For CPU, memory, disk and network thresholds, an incident *opens* when
the threshold is crossed (after `sustain_sec`, for CPU and memory) and *closes* only when the value has been clearly
back to normal for a while. A value hovering around the threshold, such as RAM going 95.2 → 94.8 → 95.1 %, stays one
incident. Two optional fields on any threshold tune this:

| Field | Meaning | Default |
|---|---|---|
| `clear_margin` | How far below the threshold the value must drop: percentage points (CPU, memory, disk) or ms (latency). | 5 points (CPU/memory), 2 points (disk), 20 % of `latency_ms` |
| `clear_sec` | How long it must stay there before the incident closes. | `sustain_sec` (CPU/memory), one check interval (disk, network) |

`"condition": "unreachable"` closes once the host answers again for `clear_sec`. While a higher level (critical) is
open, a lower level (warning) does not fire.

**2. Spam guard.** The first alert of an incident runs every configured action. While the incident stays open, repeat
alerts run only `log_to_file` and `run_script`; `popup` and `email_draft` wait for the next incident. You get one popup
per incident, and the log and remediation keep going.

**3. Email cooldown.** Even across separate incidents, `email_draft` opens at most one draft per item and level
within `global.email_cooldown_min` minutes (default 60, `0` turns it off). The last-sent times are saved in
`logs/alert_state.json`, so restarting the monitors does not reset the cooldown. A skipped draft is logged:

```
[2026-11-13 10:42:00] INFO email_draft for performance|memory|critical skipped: one was opened less than 60 min ago (global.email_cooldown_min)
```

Processes don't need hysteresis (they are either running or not), but their `email_draft` actions share the same
cooldown, so a process that keeps crashing doesn't open a draft every time.

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
| `{current_value}` | performance, disk, network, document | Measured value (%, % used, ms / `unreachable`, the document total, or the file size in `size_unit`) |
| `{percent}`, `{sustain_sec}` | performance | Threshold settings |
| `{percent_used}`, `{free_gb}` | disk | Threshold and current free space |
| `{host}`, `{port}`, `{latency_ms}` | network | Target and latency threshold |
| `{document}`, `{target}`, `{unit}` | document | Display name, target and unit (`unit` for `sum`, `size_unit` for `file_size`) |
| `{current_percent}`, `{percent_of_target}` | document | Total as % of target, and the threshold |

---

## State files

Each monitor writes a JSON state file to `logs/` on every cycle. The console reads them:

| Monitor | File | Main content |
|---|---|---|
| process | `process_state.json` | `processes[]`: `is_running`, `down_since`, `alert_count` |
| performance | `performance_state.json` | `metrics[]`: `current_value`, `current_level` |
| disk | `disk_state.json` | `drives[]`: `percent_used`, `free_gb`, `current_level` |
| network | `network_state.json` | `hosts[]`: `reachable`, `latency_ms`, `current_level` |
| document | `document_state.json` | `documents[]`: `measure`, `total`, `target`, `unit`, `percent_of_target`, `current_level`, `error`, `note` |

Every file has an `updated` timestamp. The console and the doctor treat a monitor as alive only while
`now - updated < 2 × check interval + 15 s`.

## Adding a monitor type

1. Create `scripts/monitor_<type>.ps1`. Mirror an existing monitor: dot-source `lib\MonitorCommon.ps1` and
   `lib\MonitorActions.ps1`, load with `Get-MonitorSettings`, fire actions with `Invoke-MonitorActions`, and write a
   state file.
2. Add it to `$MONITORS` in `scripts/start_monitoring.ps1` and to `$MONITOR_SCRIPTS` in `scripts/stop_monitoring.ps1`.
3. Add its section to `monitoring_settings.json` and bump `_meta.version`.
4. Add its state file to `$MonitorDefs` and its schema rules to `Test-DoctorConfig` in `scripts/lib/Doctor.psm1`.
5. Add a card and a render block in `web/console.html` (and its key in `MONITOR_SCRIPTS` in
   `MonitoringConsole/monitoring_console.py`), and a panel in `monitoring_editor.html`.
6. Add Pester cases. The script-quality tests pick up the new file automatically.
