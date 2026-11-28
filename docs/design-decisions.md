# Design decisions

The main choices behind the project, what each one costs, and what I'd revisit.

## 1. One JSON file as the single source of truth

Every monitor, threshold and action lives in `monitoring_settings.json`. The monitors, the console, the editor and
the doctor all read the same file.

- **Why:** behavior can be reviewed in one place, versioned in git, and edited without touching code. Adding a
  watched process or changing a threshold is a config change, not a deploy.
- **Cost:** a bad edit can break everything at once. That's why there's a doctor, a preflight in the launcher,
  and server-side validation in the editor (section 6).

## 2. Files as the integration layer

Monitors don't talk to the console. Each one writes `logs/<monitor>_state.json` on every cycle, and the console reads
those files when it is asked for status.

- **Why:** no broker, no shared process, no ports between components. A monitor can crash, hang or be restarted
  without affecting the others or the dashboard.
- **Heartbeat for free:** a state file older than `2 × check interval + 15 s` means the monitor is dead or stuck.
  A hung monitor shows up as stale; it can't keep looking healthy.
- **Cost:** status is only as fresh as the slowest interval. For a single-host tool that trade is fine. The
  console narrows the gap for processes with a live `tasklist` check whenever the engine is fresh.

## 3. One process per monitor

Five small PowerShell scripts, each in its own process, each on its own interval.

- **Why:** isolation. A slow Excel read in the document monitor can't delay CPU sampling. The console can pause and
  resume any single monitor, and a crash affects exactly one area.
- **Cost:** each monitor repeats its own loop and state-file code. Everything else is shared: settings loading, path
  resolution and popups live in `scripts/lib/MonitorCommon.ps1`, and the four action types live once in
  `scripts/lib/MonitorActions.ps1`. A test checks that no monitor keeps its own copy of the action code.

## 4. PowerShell for collection, Python for the UI

- **PowerShell 5.1** ships with every supported Windows version and has first-class access to WMI/CIM, performance
  counters and COM. Nothing needs to be installed to collect data.
- **Python's standard library** (`http.server`) gives a small, dependency-free web server. There's no `pip install`,
  no framework and no build step.
- **The dashboard is a single embedded HTML/JS page** with no frontend toolchain.

Hard-won PowerShell 5.1 rules, enforced by tests:

| Rule | Why |
|---|---|
| No non-ASCII characters in string literals | PS 5.1 reads `.ps1` files as Windows-1252, so UTF-8 symbols are corrupted at parse time. Use `[char]0x25CF`. |
| No `Set-StrictMode -Version Latest` | It makes a missing property a terminating error, which kills a long-running loop. Use `try/catch` per item. |
| Never use `$PID`, `$Matches`, `$Args` as variables | They're automatic variables. `foreach ($pid in ...)` fails, and under `SilentlyContinue` the loop silently never runs. This was a real bug in the stop script. |
| Spawn `powershell.exe` explicitly | Avoids picking up PowerShell 7 (`pwsh`) on machines that have both. |
| Read settings with `-Encoding UTF8` | Otherwise non-ASCII text in templates is decoded as Windows-1252. |

## 5. Hidden launch through VBScript

Monitors are started with `wscript run_hidden.vbs <script>`, not `Start-Process -WindowStyle Hidden`.

- **Why:** when Windows Terminal is the default terminal application, it intercepts console windows and ignores
  `-WindowStyle Hidden`, leaving five terminal windows open. `WScript.Shell.Run(..., 0)` creates a truly windowless process.
- **Cost:** a hidden process has no visible error output. Section 6 makes up for that.

## 6. Fail loudly at start, run quietly afterwards

A monitor that dies on startup is invisible, and a monitor whose action silently does nothing is worse. Two layers
deal with this:

- **`doctor.ps1`** checks the environment, the config schema (types, ranges, required fields, naming conventions),
  every path (log folder, every `run_script` target, the workbook, drives) and the runtime (each monitor alive,
  single-instance, writing fresh state; ports owned by this project). The checks live in a module so they can be unit tested.
- **The launcher's preflight** runs the config, path and environment checks *before* stopping running monitors. A
  broken edit is reported on screen, and the working monitors keep running.

Inside the loops the opposite applies: `$ErrorActionPreference = 'Continue'` and per-item `try/catch`, because a
monitor that stops on a transient WMI error is worse than one that skips a cycle.

## 7. A spam guard on alerts

The first alert for a condition runs all of its actions. Repeats run only `log_to_file` and `run_script`, until the
condition clears.

- **Why:** a popup or an email every 5 seconds trains people to ignore alerts. Logging and remediation should keep going
  for as long as the problem lasts.

## 8. Localhost-only, same-origin web APIs

Both servers bind to `localhost`. Every `POST` must also come from the server's own page:

- the `Host` header must be `localhost:<port>` or `127.0.0.1:<port>` (this blocks DNS rebinding);
- the `Origin` header, which browsers always send on cross-site requests, must match it.

Without this, any web page open in the browser could rewrite the settings, including the `run_script` paths, which
amounts to code execution. It could also stop the monitors, or use `/api/open-file` to launch arbitrary files.
`/api/open-file` now only opens spreadsheets inside the project folder. Tests cover each case.

## 9. Docker: a demo container, not containerized monitoring

The monitors watch the Windows machine they run on: its processes, perf counters, drive letters, desktop and Excel.
A container is built to be isolated from exactly that, and Windows 11 Home only runs Linux containers anyway. So the
monitors stay a native install.

What did containerize cleanly is the part that never depended on Windows: the stdlib console and editor. Because the
monitors and the UI only exchange JSON state files (section 2), a small simulator can stand in for the monitors.

- **Why:** anyone can try the real UI on any OS with `docker compose up`, and CI proves it on Linux.
- **How:** one image with three processes sharing one copy of the files (simulator, editor, console). Off Windows the
  console is read-only. Ports are published on `127.0.0.1` only, so the Host/Origin checks keep working.
- **Cost:** the container shows simulated system metrics, and says so in its banner. Only the document monitor and the
  localhost network checks are real there.

The full explanation is in [docker.md](docker.md).

## 10. The AI explains; the monitors decide

The incident assistant (v1.7.0) answers two questions an alert leaves open: *why* did this cross the line, and
*what do I do now*. It explains one incident and drafts the ticket text. It decides nothing.

- **Read-only tools.** The model can call four tools: `get_incident`, `get_recent_events`, `get_runbook`,
  `get_monitor_config`. They read the state files, `logs/monitor.log` and the config (e-mail addresses redacted).
  No tool pauses a monitor, edits the settings, runs a script or sends anything, and a test checks the registry for
  side effects.
- **Code owns the decisions.** Thresholds, levels, actions and ticket priority, impact, urgency and category come from
  the config and the monitors. The model writes the short description, the description and the work notes. It
  cannot change the other fields.
- **Grounded numbers.** Every number in an answer must appear in a tool result. An answer check, like the one in
  luna-hybrid-agent, flags any number it cannot trace.
- **Data is data.** Process names, document values and log lines go to the model as tool results, never as
  instructions. The evaluation includes prompt-injection cases for each of these sources.
- **Off the monitor loop.** The monitors never wait on the model. The `file://` ticket preview that a monitor
  opens stays rule-based. *Draft with AI* lives in a copy of the same `web/ticket.html` that the console serves
  at `/tickets/<number>`, behind the console's same-origin checks.
- **No answer before the data.** The number check cannot catch a guess that has no numbers. So the loop
  accepts an answer only after `get_incident` and `get_runbook` returned data. In testing, qwen3:4b sometimes
  answered on its first call, and when asked to read first it invented an incident id. Now, when the model answers
  early, the console makes those reads itself, with the incident it already loaded, and asks again. The trace
  shows them as "read by the console", so the evaluation still sees what the model did on its own.
- **Incidents are persisted.** So the assistant can read an incident's start time, sustain and peak,
  `Invoke-ThresholdAlerts` writes the open incidents (`monitor:target:level`) into each state file. Before
  v1.7.0 they lived only in the monitor's memory. Each threshold can also carry an optional `runbook` text, and
  processes keep `instructions`.

## 11. Ollama over the standard library

The project's promise is "Python standard library only". The assistant keeps it: `OllamaClient` talks to Ollama's
native `/api/chat` with `tools` through `urllib.request` and `json`. It uses no SDK and no agent framework.

- **Local by default.** `ai.ollama_url` must be a loopback address unless `ai.allow_remote: true`, so incident
  data stays on the machine. The default model is `qwen3:4b-instruct-2507-q4_K_M`, the model luna-hybrid-agent was
  evaluated on, with native tool calling. Use `qwen2.5:3b` on 8 GB machines.
- **Bounded and traced.** One run makes at most `ai.max_model_calls` model calls (default 5), with a timeout per
  call and a token budget. Every run is saved as JSON under `logs/ai_traces/` (rotated), and the console's
  *Agent steps* view reads it from `GET /api/ai/runs/{id}`, polled while the run is in progress. Polling was chosen
  over SSE so the console can stay single-threaded.
- **Off by default.** `ai.enabled` is `false` in the shipped config. When Ollama is not reachable, a `DemoClient`
  (templates and rules, no model) answers instead, and the UI labels it "Demo (rules, no AI)". The Docker demo uses
  it. A `FakeClient` scripts the model for the tests.
- **The doctor checks it.** If Ollama is reachable and the model is present, the check is `OK`. Otherwise it is a
  `WARN`, never a `FAIL`, because the monitors work without the assistant.

## 12. Evaluating the assistant

About 20 incident scenarios: one per monitor type and level, a recovery, a missing runbook, a stale monitor, prompt
injection through a process name, a CSV value and a log line, and one in Spanish. Each run is scored from its trace:
right tools called, the facts (metric, value, threshold, duration), no untraced numbers, runbook cited, ticket
priority unchanged, injection ignored. CI runs the suite with `FakeClient` and requires 100 %. A run on the real
local model is written up in `docs/eval/`, failures included.

## Known limitations

- **Windows-only by design.** The Docker image is a demo with simulated monitors; see section 9.
- **`.xlsx` documents use Excel COM.** Each read starts Excel, which is slow (seconds) and requires Office; CSV
  documents avoid it entirely, which is why the default is a CSV. The Excel read runs in a short-lived child process
  (`scripts/lib/Read-XlsxTotal.ps1`), because Excel only exits when the process that drove it ends normally.
  Force-stopping a long-lived monitor that held Excel left orphaned hidden `EXCEL.EXE` processes.
- **`email_draft` never delivers email unattended.** It shows a simulated incident ticket first, and the person
  decides whether to open the `mailto:` draft and send it. No real ticketing system is contacted.
- **`run_script` handlers run synchronously** inside the monitor loop. Long tasks must be started detached.
- **CPU sampling uses an English performance-counter path**, which fails on some localized Windows installs. The
  doctor detects this.
- **Monitors run in the user session** and stop at logoff. Running them as a Windows service is on the roadmap.
