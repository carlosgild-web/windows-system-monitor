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
  "ai":          { ...the incident assistant (optional, off by default)... },
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

## `ai` (incident assistant, v1.7.0)

Optional. A local [Ollama](https://ollama.com) model explains one incident and drafts the ticket text, using
read-only tools over the state files, the log and this file. It decides nothing: levels, priorities and actions
always come from the settings. Without this section, or with `enabled: false`, *Explain* uses the rules, no AI.
See [design decisions 10-12](design-decisions.md#10-the-ai-explains-the-monitors-decide).

```json
"ai": {
  "enabled": false,
  "ollama_url": "http://localhost:11434",
  "allow_remote": false,
  "model": "qwen3:4b-instruct-2507-q4_K_M",
  "fallback_model": "qwen2.5:3b",
  "timeout_sec": 90,
  "max_model_calls": 5,
  "token_budget": 12000,
  "max_traces": 200
}
```

| Field | Type | Description |
|---|---|---|
| `enabled` | bool | Turns the assistant on. `false` in the shipped file. |
| `ollama_url` | http(s) URL | Where Ollama listens. Must be this machine (`localhost`, `127.x.x.x`, `::1`) unless `allow_remote` is `true`. |
| `allow_remote` | bool | Allows another host. Incident data then leaves this PC, and the doctor says so (`WARN`). |
| `model` | string | Ollama model tag. The default has native tool calling. |
| `fallback_model` | string, optional | Used when `model` is not pulled, for example `qwen2.5:3b` on an 8 GB machine. |
| `timeout_sec` | number > 0 | Timeout for each model call. |
| `max_model_calls` | whole number 1-20 | Model calls per run. A run stops at this limit. |
| `token_budget` | whole number >= 500 | Prompt plus output tokens per run. |
| `max_traces` | whole number >= 1 | Run traces kept in `logs/ai_traces/` (oldest deleted first). |

The doctor validates the section (any error is a `FAIL`) and, when the assistant is enabled, checks that Ollama
answers and the model is pulled. That check is a `WARN` at most, never a `FAIL`: the monitors work without the
assistant.

**Runbooks.** Any threshold (CPU, memory, disk, network, document) can carry an optional `runbook` text: what to do
when it fires, as numbered steps. The assistant reads it with its `get_runbook` tool and cites it. Processes keep
their runbook in the `instructions` of their `on_not_running` action, as before.

```json
{ "level": "critical", "percent_used": 90, "runbook": "1. Run Disk Cleanup...\n2. ...", "actions": [ ... ] }
```

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
| `email_draft` | Shows the alert as a simulated incident ticket (see below), where you preview the email and open it in your mail client. | `to`, `subject_template`, `body_template` |
| `run_script` | Runs a PowerShell script with arguments. | `path`, `args[]` |

¹ Process actions use `instructions` instead of `message_template`.

### The ticket preview (`email_draft`)

An `email_draft` action doesn't open your mail client straight away. It first opens a small window with the alert
presented as an incident in an ITSM tool such as ServiceNow: a number (`INC0010001`, ...), state, category,
configuration item (the computer name), impact, urgency, priority, severity, assignment group, the description
(your `body_template`) and an activity log. **It is a simulation**: no ticket is created anywhere and nothing is
sent.

1. **Ticket.** Review the incident. **Dismiss** closes it.
2. **Preview notification email.** Shows From (`global.email_sender`), To, Subject and the body.
3. **Open in email app.** Opens the pre-filled draft in your default mail client (a `mailto:` link), where you
   send it or not. **Copy email text** copies it instead.

How the fields are filled:

| Field | From |
|---|---|
| Priority, impact, urgency, severity | The threshold level: `critical` → P1 (1 - Critical), `warning` → P3 (3 - Moderate) |
| Category, subcategory, assignment group | The monitor (e.g. disk → Hardware / Storage / Server Operations); simulated |
| Short description, description | The expanded `subject_template` and `body_template` |
| Configuration item, opened | `{hostname}` and `{timestamp}` |

Each ticket is saved as `logs/tickets/<number>.html` (open it again any time) from the template
[`web/ticket.html`](../web/ticket.html); the next number is kept in `logs/tickets/next_number.txt`. The window is a
Microsoft Edge app window (no tabs or address bar), or the default browser when Edge is missing. It is sized to fit
the screen the mouse pointer is on (at most 900 × 880, centered), and its buttons stay visible while the ticket
scrolls. If the preview can't be created, the email opens directly as before, so an alert is never lost.

A ticket opens once per item and level per hour (the [email cooldown](#incidents-spam-guard-and-email-cooldown)
below); saving the settings starts that hour over.

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
`logs/alert_state.json`, so restarting the monitors does not reset the cooldown. Saving `monitoring_settings.json`
(in the editor or by hand) does: a changed threshold is a new test, so the next incident after a save opens a ticket
again, while a value flapping on its own stays limited. A skipped draft is logged:

```
[2026-11-13 10:42:00] INFO email_draft for performance|memory|critical skipped: one was opened less than 60 min ago (global.email_cooldown_min; saving the settings resets it)
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

Since v1.7.0 every state file also lists its open incidents under `incidents` (the incident assistant reads them).
The threshold monitors write them from `Invoke-ThresholdAlerts`; the process monitor lists a required process that is
down. Each entry:

```json
{
  "id": "performance:cpu:critical",
  "monitor": "performance", "target": "cpu", "level": "critical",
  "opened_at": "2026-11-28 10:00:30", "exceeded_since": "2026-11-28 10:00:00",
  "sustain_sec": 30, "threshold": 95, "peak": 99.1, "last_value": 97.2, "alert_count": 3
}
```

`exceeded_since` is when the value first crossed the threshold, and `opened_at` is when the incident opened (after
`sustain_sec`). `peak` is the worst value while it was open (the lowest for a `below` document threshold). A document's
values are its percent of target. An unreachable host has no value, so `peak` and `last_value` are `null`.

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
