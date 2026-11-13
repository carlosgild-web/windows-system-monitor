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

## Known limitations

- **Windows-only by design.** The Docker image is a demo with simulated monitors; see section 9.
- **`.xlsx` documents use Excel COM.** Each read starts Excel, which is slow (seconds) and requires Office; CSV
  documents avoid it entirely, which is why the default is a CSV. The Excel read runs in a short-lived child process
  (`scripts/lib/Read-XlsxTotal.ps1`), because Excel only exits when the process that drove it ends normally.
  Force-stopping a long-lived monitor that held Excel left orphaned hidden `EXCEL.EXE` processes.
- **`email_draft` opens a `mailto:` draft** for a person to send. It doesn't deliver email unattended.
- **`run_script` handlers run synchronously** inside the monitor loop. Long tasks must be started detached.
- **CPU sampling uses an English performance-counter path**, which fails on some localized Windows installs. The
  doctor detects this.
- **Monitors run in the user session** and stop at logoff. Running them as a Windows service is on the roadmap.
