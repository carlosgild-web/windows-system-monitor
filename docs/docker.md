# Docker: what runs in a container, and what can't

**Short version:** `docker compose up --build` runs the real web console and settings editor on any OS, fed by
**simulated** monitors. The real monitors stay a native Windows install, because their whole job is to watch the
Windows machine they run on, and a container is built to *not* see that machine.

```bash
docker compose up --build        # console: http://localhost:5758   editor: http://localhost:5757
docker compose down
```

## Why the PowerShell monitors can't run in a container

The monitors don't just *use* PowerShell; they use Windows itself:

| Monitor | What it calls | In a Linux container | In a Windows container |
|---|---|---|---|
| Processes | `Get-Process`, `tasklist` | PowerShell 7 runs, but sees only the container's own processes. `explorer.exe` is never "running". | Same: it sees the container's processes, not the host's. |
| CPU / memory | `Get-Counter` (perf counters), `Win32_OperatingSystem` (CIM) | Neither exists on Linux. | Exists, but measures the container's own limits. |
| Disk | `Win32_LogicalDisk` | Doesn't exist; there are no drive letters. | Sees the container's virtual disk, not your `C:`. |
| Network | .NET `Ping`, `TcpClient` | Works. | Works. |
| Document (Excel) | Excel COM automation | No Excel, no COM. | Microsoft doesn't support Office automation in containers (no desktop session, licensing). |
| Actions | `MessageBox` popups, `Start-Process mailto:` | No desktop, no mail client. | No interactive desktop either. |

On top of that, **Windows 11 Home only runs Linux containers**. Docker Desktop uses WSL 2 there, and Windows
containers need Pro or Enterprise with Hyper-V.

So a container can't do the monitoring. That isn't a gap in the scripts: isolation is the point of a container, and
watching the host is the point of these monitors.

## What the demo container does instead

The container runs three processes (`docker/run_demo.py`) that share one copy of the project files:

```
docker/simulator.py ──writes──► logs/*_state.json ◄──reads── monitoring_console.py (:5758)
        │ reads every cycle                                         │
        └──────────── monitoring_settings.json ◄──writes── server.py (:5757, the editor)
```

- **The console and the editor are the real ones**, unchanged. They are standard-library Python, which is what made
  this possible: the monitors and the UI only talk through JSON files (see [design decisions](design-decisions.md#2-files-as-the-integration-layer)).
- **`docker/simulator.py`** stands in for the five monitors and writes the same state files they write:

  | | Source |
  |---|---|
  | Processes | From the settings; Notepad "closes" for 50 s out of every 150 s, the others run |
  | CPU / memory | Random walk, with a spike past the critical threshold every few minutes |
  | Disk | Slowly drifting usage around 75–80 % |
  | Network, public hosts | Simulated latency |
  | Network, `localhost` targets | **Real** TCP checks against the console and editor in the container |
  | Document | **Real**: it reads the CSV and applies its above/below thresholds |

  Levels are computed from the thresholds in `monitoring_settings.json`, which the simulator re-reads every cycle:
  change a threshold in the editor and the console follows a few seconds later.
- **Off Windows, the console is read-only.** There are no Pause/Resume buttons, because there are no PowerShell
  processes to stop. The banner says the data is simulated, and opening a spreadsheet from the editor explains why it
  can't.

## Security notes

- The image is `python:3.12-slim` with **no extra packages** (standard library only) and runs as a **non-root user**.
- Inside the container the servers listen on `0.0.0.0`, but `docker-compose.yml` publishes them on **`127.0.0.1`
  only**, so the demo isn't reachable from your network. Because the browser still talks to `localhost:5758`, the
  servers' Host/Origin checks (CSRF and DNS-rebinding protection) keep working unchanged.
- On Windows nothing changes: both servers keep binding to `localhost`.

## Checked in CI

The `Docker demo` job in [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) builds the image on Ubuntu, starts it,
and runs `docker/smoke_test.py`. The smoke test checks that:

- every monitor is reported live;
- the document total comes from the real CSV;
- the console is read-only and in demo mode;
- the editor row is online;
- both pages and their assets load;
- the editor and console read the same settings.

You can run the same test locally:

```bash
docker compose up --build -d && python docker/smoke_test.py && docker compose down
```

## If you wanted real monitoring in a container

The realistic path would be a different product: cross-platform collectors (`psutil` for processes, CPU, memory and
disks; `openpyxl` for workbooks) running **on the host**, with only the dashboard containerized. That's on the roadmap
as "cross-platform collectors". For a tool that watches one Windows PC, a native install plus this demo container
covers both audiences.
