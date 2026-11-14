# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

A Windows monitoring and auto-remediation toolkit: a declarative JSON config, five PowerShell monitors, a Python web
dashboard, a settings editor, a health-check "doctor", and bat-file launchers. The config
(`monitoring_settings.json`) is the source of truth; every other component reads from it. Public portfolio repo:
keep personal data (real emails, names, phone numbers, hostnames, absolute paths) out of committed files.

## Workflow

`master` is protected: it only changes through a pull request with a green CI run (squash merge). Work on
`feature/*` branches, add an entry under `Unreleased` in `CHANGELOG.md`, and follow the checklist in
`.github/pull_request_template.md`. Releases are tagged `vX.Y.Z` and match `_meta.version`.

## How to run things

| Task | Command |
|---|---|
| Health check (env, config, paths, runtime) | `doctor.bat` (`scripts\doctor.ps1 -SkipRuntime` for config only) |
| Start all monitors + open console | `start_monitoring.bat` (runs a preflight first) |
| Stop all monitors + close console | `stop_monitoring.bat` |
| Open the settings editor | `start_editor.bat` → `http://localhost:5757` |
| Run the web console manually | `python MonitoringConsole\monitoring_console.py` → `http://localhost:5758` |
| Python tests | `python -m unittest discover -s tests/python` |
| PowerShell tests | `Invoke-Pester tests/powershell` (Pester 5.5+) |
| Docker demo (simulated monitors) | `docker compose up --build`, then `python docker/smoke_test.py` |

`start_monitoring.bat` calls `scripts/start_monitoring.ps1`, which: (0) runs the doctor's config/path/environment
checks and aborts **without touching running monitors** on any FAIL, (1) stops running monitors, (2) launches each
entry of `$MONITORS` hidden via `wscript run_hidden.vbs`, (3) waits until all are running, then (4) starts the console.

## Architecture

```
monitoring_settings.json ←→ server.py (:5757) ←→ monitoring_editor.html
        │
        ├── scripts/process_monitor.ps1      → logs/process_state.json
        ├── scripts/performance_monitor.ps1  → logs/performance_state.json
        ├── scripts/monitor_disk.ps1         → logs/disk_state.json
        ├── scripts/monitor_network.ps1      → logs/network_state.json
        └── scripts/monitor_document.ps1     → logs/document_state.json
                                                   │
                     MonitoringConsole/monitoring_console.py (:5758)
                     reads config + state files; live tasklist check for processes
```

- **Monitors** each run in their own hidden PowerShell process, fire actions on threshold/transition, and write their
  state file every cycle. A state file is fresh if `updated` is within `2 × check interval + 15 s`.
- **`scripts/lib/MonitorCommon.ps1`** (dot-sourced by every monitor): `Get-MonitorSettings` (UTF-8 load + resolves
  relative `global.log_file` / `global.scripts_dir` against the project root), `Resolve-ProjectPath`,
  `Show-MonitorPopup`.
- **`scripts/lib/MonitorActions.ps1`** (dot-sourced by every threshold monitor after `MonitorCommon.ps1`): the four
  action types, once. `Invoke-MonitorActions -Actions -Vars -GlobalCfg [-SuppressSpam]`, `Expand-Template`,
  `Write-MonitorLog` (rotating log writer). Never copy action code into a monitor; a test enforces this.
- **`scripts/lib/Doctor.psm1`**: all health checks (`Test-DoctorEnvironment/Config/Paths/Runtime`, `Invoke-Doctor`).
  Used by `doctor.ps1`, the launcher preflight, and the Pester tests.
- **`scripts/lib/DocumentReader.ps1`**: the document monitor's reader. `.csv` is read in-process (no Excel);
  `Get-DocumentChecks` builds its above/below threshold checks.
- **`scripts/lib/Read-XlsxTotal.ps1`**: for `.xlsx` documents, run as a short-lived child process for every
  workbook read. Excel COM only exits when the driving process ends normally, so never move Excel automation back
  into a long-lived monitor process (force-stopping it would orphan a hidden `EXCEL.EXE`).
- **`scripts/actions/on_*.ps1`**: sample `run_script` handlers, built on `scripts/lib/ActionHandler.ps1`
  (`ConvertFrom-HandlerArgs`, `Write-HandlerLog`). They run in-process inside the monitor loop: keep them fast.
- **Web servers** (stdlib only) bind to localhost and reject any POST whose `Host`/`Origin` is not their own page
  (CSRF / DNS-rebinding protection). They read the request body before replying, because an early reply with
  unread data resets the connection on Windows. Keep both properties when adding endpoints.
- **Off Windows** (`os.name != "nt"`, the Docker demo) the console is read-only: no `tasklist`, no start/stop, no
  spawning the editor; `/api/status` reports `capabilities` and `demo_mode`. Environment: `BIND_HOST` (default
  `localhost`), `NO_BROWSER`, `DEMO_MODE`, `EDITOR_HOST` (where the console probes the editor). Never bind to
  anything but localhost on Windows.
- **`docker/`**: `simulator.py` writes the same state files as the monitors (re-reads the settings every cycle; keep
  its output in step with the monitors' state-file formats), `run_demo.py` runs simulator + editor + console in one
  container, `smoke_test.py` is the CI check. New files the image needs must be added to the `Dockerfile` COPY lines.
- **`POST /api/monitors/start|stop`** (console, the demo banner): starts the missing monitors / stops all five,
  matched on the full script path so another copy of the project on the machine is left alone. The console and
  the editor keep running.
- **`POST /api/open-editor`** (console): starts `server.py --no-browser` hidden with its full path (that's how
  `stop_monitoring.ps1` finds it) unless port 5757 already answers, waits for it, and returns its URL. When 5757
  already answers, it opens it only if the editor's `GET /api/identity` `copy_id` (hash of the project folder,
  `copy_id()` in both `server.py` and the console; a test keeps them equal) matches its own; otherwise it returns
  `foreign_editor: true` and an explanation.
- **Web UI**: the console page is `web/console.html` (plain HTML/JS, no build step); the editor is
  `monitoring_editor.html`. Both load `web/static/theme.css` (color tokens, light + dark), `theme.js` (theme switch)
  and `icons.svg` (sprite: `<svg class="icon"><use href="/static/icons.svg#i-name"/></svg>`) through a `/static/`
  route that only serves whitelisted file types from inside `web/static/`. The editor links them relatively
  (`web/static/...`) so it also works opened from disk; the servers accept both `/static/` and `/web/static/`.
  No CDNs: the app must work offline. The editor's `a11yPass()` links generated labels to fields and makes
  collapsible headers keyboard buttons; call it (via `updateBadges()`) after any new render function.
  Status colors (`--ok/--warn/--crit`) are for status only; controls stay neutral or use `--accent`.

## Configuration schema

Always bump `_meta.version` and update `_meta.last_updated` when modifying `monitoring_settings.json`, and run the
doctor afterwards. Full reference: `docs/configuration.md`.

- **Field-name split:** process `on_not_running` actions use `instructions` (shown in the console's runbook modal);
  every other section uses `message_template`. The editor enforces this in `actionFields()`; the doctor checks it.
- **Levels:** `warning` → `popup`, `log_to_file`; `critical` → may also use `email_draft`, `run_script`.
- **Spam guard (all monitors):** repeat alerts run only `log_to_file` and `run_script`.
- **Incidents (CPU/memory/disk/network):** `Invoke-ThresholdAlerts` opens an incident after `sustain_sec` and closes it
  only after the value stays below `threshold - clear_margin` for `clear_sec` (optional per-threshold fields).
- **Email cooldown:** one `email_draft` per `monitor|item|level` per `global.email_cooldown_min` (default 60),
  persisted in `logs/alert_state.json` (shared by all monitor processes, guarded by a named mutex).
- **Template variables:** `{timestamp}`, `{hostname}`, `{global.<field>}` everywhere; `{proc_name}`, `{proc_display}`
  (processes); `{current_value}`, `{percent}`, `{sustain_sec}` (CPU/memory); `{current_value}`, `{percent_used}`,
  `{free_gb}` (disk); `{host}`, `{port}`, `{current_value}`, `{latency_ms}` (network; `{latency_ms}` is the threshold);
  `{document}`, `{current_value}`, `{current_percent}`, `{target}`, `{unit}`, `{percent_of_target}` (document;
  for `measure: "file_size"`, `{current_value}` and `{target}` are in `size_unit` and `{unit}` is that unit).
- **Documents:** `document` is a list (a v1.6 single object is still accepted: normalize with `@($cfg.document)` /
  `as_list()` / `normalizeSettings()`). `display_name` must be unique. `measure` is `sum` (default) or `file_size`;
  a missing file_size file counts as 0.

### Adding a new monitor type

1. Create `scripts/monitor_<type>.ps1`, mirroring an existing monitor (dot-source `lib\MonitorCommon.ps1` and
   `lib\MonitorActions.ps1`, fire actions with `Invoke-MonitorActions`, write a state file).
2. Add it to `$MONITORS` in `scripts/start_monitoring.ps1` and `$MONITOR_SCRIPTS` in `scripts/stop_monitoring.ps1`.
3. Add its config section and bump `_meta.version`.
4. Add it to `$MonitorDefs` and its schema rules to `Test-DoctorConfig` in `scripts/lib/Doctor.psm1`.
5. Add a render block in the console and a panel in the editor; add Pester cases.

## PowerShell coding rules (enforced by `tests/powershell/ScriptQuality.Tests.ps1`)

**No non-ASCII characters in string literals.** PowerShell 5.1 reads `.ps1` files as Windows-1252, so UTF-8
characters in quoted strings corrupt at parse time. Use `[char]0xXXXX` (e.g. `"$([char]0x25CF) RUNNING"`).
Non-ASCII in comments is safe.

**No `Set-StrictMode -Version Latest`.** It turns null/missing property access into terminating errors, which kills
the monitoring loop. Use `$ErrorActionPreference = 'Continue'` and per-item `try/catch`.

**Never assign automatic variables** (`$PID`, `$Matches`, `$Args`, `$Input`, `$Error`, ...). `foreach ($pid in ...)`
fails, and under `SilentlyContinue` the loop body silently never runs.

**Use `powershell.exe` explicitly** (not `powershell`) when spawning child processes, to avoid ambiguity with
PowerShell 7.

**Never block waiting for a key when input is redirected** (`[Console]::IsInputRedirected`); scripted and CI runs
would hang.
