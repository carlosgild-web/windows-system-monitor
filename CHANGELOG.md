# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions match
`_meta.version` in `monitoring_settings.json`.

## [Unreleased]

### Added
- `start_monitoring.bat video`: starts the test environment from a clean scratch copy (`%TEMP%\wsm-video`) with the
  incident assistant on, for recording the showcase. It refuses to start while ports 5757/5758 are in use, deletes
  only a copy it made, and leaves this project's settings and logs untouched.
- README screenshots and GIF (`docs/showcase/`), recorded by `e2e/showcase/` (Playwright, dev-only: not in the
  runtime, the Docker image or CI) on the real monitors in video mode. The GIF's model turns are a fixed script
  (`MonitoringConsole/ai/scripted.py`, used only when `WSM_AI_SCRIPT` is set, labelled *Scripted replay (no AI)*);
  the tools' results, the number check and the ticket fields are real.

- **The README video** (`docs/video.md`, 1:51): the real console and `qwen3:4b-instruct` on Ollama, with an
  "Under the hood" panel; recorded in two passes (`video/pass1.mjs`, then the take replays the model's turns and
  must match them). Tooling in `video/` (dev-only), ported from hl-bead-studio: storyboard, recorder, payload
  checks, labelled wait cuts. Poster, subtitles and a new social preview in `docs/showcase/`.

### Fixed
- *Open incidents* shows each item once, at its highest open level (a warning stays open under a critical one).
- *Draft with AI*: the ticket's Description no longer repeats the work notes (the email still carries both).

## [1.7.0] - 2026-11-28

### Added
- **Incident assistant: settings and data.** A new optional
  `ai` section (`enabled` is false in the shipped file): a local Ollama URL, which must be this machine unless
  `allow_remote` is true, plus the model, a fallback model, a timeout, a model-call limit, a token budget and the
  number of traces kept. The doctor validates it and, when it is enabled, checks that Ollama answers and the model is
  pulled (`WARN` at most, never `FAIL`). The settings editor has an *Incident Assistant (local AI)* card.
- Thresholds can carry an optional `runbook` text (numbered steps), editable in the editor. The shipped critical
  CPU, memory, disk, network and budget thresholds have one.
- Every state file lists its open incidents under `incidents`: id (`monitor:target:level`), when the value crossed
  the threshold, when the incident opened, sustain, threshold, peak, last value and alert count. Before, open
  incidents lived only in each monitor's memory. The Docker simulator writes the same list.
- `MonitoringConsole/ai/`, the assistant's model layer, standard library only: `OllamaClient` (Ollama's `/api/chat`
  with tools over `urllib`; refuses a remote URL unless allowed, never follows a redirect, ignores proxy settings,
  times out every call), `DemoClient` (rules and templates, no model, labelled "Demo (rules, no AI)"),
  `FakeClient` (scripted, for tests), and `choose_client`: the configured model, else the fallback model, else
  the rules, with the reason.
- The assistant's agent loop (`ai/agent.py`): four read-only tools (`get_incident`, `get_recent_events`,
  `get_runbook`, `get_monitor_config`, with e-mail addresses redacted) behind a registry that validates every
  argument; at most `ai.max_model_calls` calls, the last one without tools; a token budget; at most four tool calls
  per turn; a number check on the answer; the ticket's priority, impact, urgency, severity, category and group set
  by code; a hand-over to the rules when the model fails; a JSON trace per run in `logs/ai_traces/` (rotated).
  Tested against prompt injection through a process name, a document name and a log line.
- Console API for the assistant: `POST /api/ai/explain` and `POST /api/ai/ticket-draft` (JSON
  `{"incident_id", "language": "en"|"es"}`, answer 202 with a run id), `GET /api/ai/runs/{id}` (poll until the
  status is not `running`) and `GET /api/ai/status` (which client will answer, and why). One run at a time (409
  otherwise). Every `/api/ai/` route, GETs included, has the same Host/Origin checks as the other POSTs, and the
  POSTs require `Content-Type: application/json`. `/api/status` now lists the open `incidents`, and the console
  serves a monitor's ticket at `/tickets/<number>`. The Docker image includes the assistant (rules only).
- **Incident assistant in the console.** An *Open incidents* card lists every open incident with an **Explain**
  button. The panel shows the *Agent steps* as they happen (each tool call and what it returned), the answer, the
  numbers checked against the monitors' data (untraced ones highlighted), the model calls and tokens used, and who
  answered: *Local AI* with the model's name, or *Demo (rules, no AI)* with the reason. English or Spanish.
  Light and dark themes, phone width. The demo guide and `docs/test-environment.md` explain it.
- **Draft with AI** on the console's copy of a ticket (`/tickets/<number>`): the model writes the short
  description, description and work notes (also used in the email draft); the priority, impact, urgency and
  category stay as the rules set them, and the page says so. *Use the original text* undoes it. The `file://`
  ticket a monitor opens links to the console copy and makes no request itself.
- Grounding gate: the assistant's answer is only accepted after `get_incident` and `get_runbook` have returned
  data. When the model answers first (a 4B model sometimes does, or invents an incident id when asked to read),
  the console makes those two reads itself and asks again; the trace marks them "read by the console".
- **Evaluation** (`eval/assistant_eval.py`): 21 incident scenarios scored from the assistant's traces (grounded,
  facts, traced numbers, runbook, staleness, injection, ticket fields, side effects, language). CI runs them with a
  scripted reference model (100 % required) and checks the rules baseline and that the scorer fails bad answers.
  Reports in `docs/eval/`: the rules baseline (19 of 21) and two runs of qwen3:4b on a CPU-only laptop (17 and 16
  of 21), with every failure and what it changed.

- **Docker demo with a local model** (`docker compose --profile ai up`): an `ollama` container (no published port,
  on the compose network only) and a one-shot `ollama-pull` for the model (`qwen2.5:3b` by default,
  `DEMO_AI_MODEL` to change it). Without the profile, the demo's assistant answers with rules and says how to turn
  the model on. `docker/smoke_test.py --ai` checks it; see `docs/docker.md`.

### Fixed (found by the evaluation)
- The answer check missed a number at the start of a runbook line (tool results were scanned as JSON text, where
  the new line before it is the two characters `\n`), so a quoted step such as "2." was flagged as untraced.
- `get_runbook` now says in a sentence that no runbook is configured (a bare `null` was ignored), and a Spanish
  request also gets the language instruction in the system prompt.
- The rules client now gives the item's current reading (total and target, host, free space) and says when the
  monitor is stale.
- Start / Stop monitoring buttons in the console's demo banner (`POST /api/monitors/start|stop`). They act on all
  five monitors of this install only, matched by full script path; the console and the editor keep running.
- Document `measure: "file_size"`: watch a file's size in KB, MB or GB against a target. A file that does not exist
  yet counts as 0.
- Two more sample documents: Eating out spend (budget CSV) and Monitor log size (`logs\monitor.log`).
- The editor's Document section has **+ Add Monitor**, Remove and a Measure picker.
- **Ticket preview for `email_draft`**: instead of opening the mail client straight away, the alert opens as a
  simulated ServiceNow-style incident (number, state, category, configuration item, impact, urgency, priority,
  severity, assignment group, description, activity). From there you preview the notification email and open it in
  your mail client. Saved in `logs/tickets/`; template `web/ticket.html`. The window fits the screen it opens on
  (at most 900 × 880, centered) and its buttons stay visible while the ticket scrolls.
- Saving the settings restarts the email cooldown, so the next incident after you change a threshold opens a
  ticket again (it used to stay silent for up to an hour; the log said why, but nothing on screen did).

### Changed
- `document` is now a list, like `disk` and `network` (`_meta.version` 1.7.0). A v1.6 single object is still
  accepted everywhere. `document_state.json` now holds a `documents` list, and `/api/status` returns `documents`.
- The doctor checks every document, flags duplicate names, and only warns when a file_size file does not exist yet.
- The Document card is first on the console.
- The settings editor shows every monitor collapsed (Processes, Disk, Network, Document cards, and all thresholds)
  each time you open a section, so you unfold only the one to edit. Within a section, what you unfold stays
  unfolded through saves; a monitor you just added opens.

### Fixed
- **Open Monitoring settings** no longer opens the editor of another copy of the project. When port 5757 is
  already taken, the console asks the editor which copy it belongs to (new `GET /api/identity`: a hash of the
  project folder plus the settings version, never the path). It opens the editor only when it matches, and
  otherwise says what is on the port and to stop it. Before, a stale editor from another folder could show
  different settings than the console.
- The settings editor keeps cards and thresholds collapsed or expanded as you left them after saving, reloading,
  adding a threshold or removing an item. Before, it expanded everything again.

## [1.6.0] - 2026-11-13

A portfolio-ready release: a redesigned UI with a built-in demo guide, a default test environment that works
on any Windows PC, deduplicated alerts, a generic CSV/Excel document monitor, and a Docker demo.

### Added
- **Illustrations made with Google Gemini**: an app icon, a picture for the "How this demo works" panel, empty /
  paused / error state art in the console, and the README hero and social preview. Every slot has a fallback, so the
  app works without them; `docs/images.md` and `tools/prepare_images.py` show how to make them again.
- A **Docker demo**: `docker compose up --build` runs the real console and settings editor on any OS, fed by
  `docker/simulator.py` (simulated CPU, memory, disk and public hosts; the budget CSV and localhost checks are real).
  Non-root, standard library only, published on 127.0.0.1. A CI job builds it and runs `docker/smoke_test.py`.
  [docs/docker.md](docs/docker.md) explains why the PowerShell monitors themselves can't run in a container.
- A **portfolio demo banner** on the console: what the project is, a "How this demo works" panel (what it is, how
  the pieces fit, things to try) and an **Open Monitoring settings** button that starts the settings editor in the
  background if needed (`POST /api/open-editor`, same-origin only) and opens it in a new tab. The banner can be
  collapsed to a "Demo guide" pill. `stop_monitoring.bat` also stops an editor started this way.
- A generic **document monitor** replaces Ebook Sales: it sums a filtered column of a `.csv` (no Excel needed) or
  `.xlsx` file and alerts when the total goes `above` or `below` a percent of a target, with the same actions,
  hysteresis and email cooldown as the other monitors. The default watches a made-up monthly budget CSV.
- A **default test environment** that works on any Windows 10/11 PC: Explorer, the Desktop Window Manager and
  Notepad (demo), CPU/RAM, `C:`, Cloudflare and Google DNS, the console and the settings editor (demo), and the
  budget CSV. [docs/test-environment.md](docs/test-environment.md) shows how to trigger every alert.

### Fixed
- Accessibility: every editor field is now linked to its label (196 of 199 were not), collapsible sections open
  with Enter/Space, and console dialogs move focus inside on open and back on close.
- A metric hovering around a threshold no longer opens a new email draft every time it dips and comes back. CPU,
  memory, disk and network alerts use hysteresis (optional `clear_margin` / `clear_sec` per threshold), and
  `email_draft` is limited to one per item and level per `global.email_cooldown_min` (default 60), saved in
  `logs/alert_state.json` so it survives restarts.

### Changed
- The console and the settings editor also run off Windows (the Docker demo): the console becomes read-only (no
  live `tasklist` check, no pause/resume, no launching the editor), `/api/open-file` explains instead of failing,
  and `BIND_HOST`, `NO_BROWSER`, `DEMO_MODE` and `EDITOR_HOST` environment variables control the container setup.
  On Windows nothing changes: both servers still bind to localhost.
- **Redesigned web console.** An overview row (critical / warning / healthy / monitors live), cards that flow into
  as many columns as fit (one column on phones), meters with threshold ticks, one status badge per row, neutral
  Pause/Resume controls (red is only used for critical status), and light and dark themes with a switch. Info
  tooltips also open on keyboard focus. The page moved out of the Python file into `web/console.html`; a shared
  theme, SVG icon set and favicon live in `web/static/`, served by both servers at `/static/`.
- **Redesigned settings editor** on the same theme: light sidebar with icons and counts, light/dark switch, calmer
  remove buttons (red only on hover), and a phone layout where the sidebar becomes a tab strip.
- **Breaking:** the `ebook_sales` config section is replaced by `document` (the doctor warns if it is still
  present); see the upgrade note in `docs/configuration.md`. The doctor checks for Excel only when the document is
  a workbook.
- The four alert actions live once in `scripts/lib/MonitorActions.ps1` instead of being copied into each monitor.
  Side effects: template values containing `$` are inserted literally, the email recipient is escaped in every
  monitor, and rotated logs are always named `monitor.<timestamp>.log`.

## [1.5.0] - 2026-11-13

First public release.

### Added
- Five independent monitors (process, CPU/RAM, disk, network, spreadsheet metric), all driven by
  `monitoring_settings.json`.
- Escalating actions (`log_to_file`, `popup`, `email_draft`, `run_script`) with a per-incident spam guard.
- Live web console (`:5758`) and settings editor (`:5757`), both Python standard library only.
- `doctor.bat` health check (environment, config schema, paths, runtime), and a preflight in the launcher that
  blocks a broken config before any monitor is restarted.
- Sample `run_script` remediation handlers in `scripts/actions/`.
- Made-up sample workbook for the ebook sales monitor.
- Pester and Python test suites; CI on Windows PowerShell 5.1 with PSScriptAnalyzer.

### Fixed
- The editor and console APIs reject cross-origin and DNS-rebinding requests; `/api/open-file` only opens
  spreadsheets inside the project folder.
- `popup` actions work in the performance, disk and network monitors (they were silently ignored).
- Stopping the monitors no longer leaves orphaned hidden Excel processes.
- The stop script's exit wait now runs (`$PID` loop-variable bug).
- Settings are always read as UTF-8; a settings file saved with a BOM no longer blanks the console.
- Config paths are relative to the project folder, so the repo runs from any location.
- `{latency_ms}` in network templates refers to the threshold, consistent with the other monitors.

[Unreleased]: https://github.com/carlosgild-web/windows-system-monitor/compare/v1.7.0...HEAD
[1.7.0]: https://github.com/carlosgild-web/windows-system-monitor/compare/v1.6.0...v1.7.0
[1.6.0]: https://github.com/carlosgild-web/windows-system-monitor/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/carlosgild-web/windows-system-monitor/releases/tag/v1.5.0
