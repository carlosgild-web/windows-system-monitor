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
  | Document | **Real**: it reads the CSV (or the file's size) and applies its above/below thresholds |

  Levels are computed from the thresholds in `monitoring_settings.json`, which the simulator re-reads every cycle:
  change a threshold in the editor and the console follows a few seconds later.
- **Off Windows, the console is read-only.** There are no Pause/Resume or Start/Stop monitoring buttons, because there
  are no PowerShell processes to stop. The banner says the data is simulated, and opening a spreadsheet from the editor explains why it
  can't.

## The incident assistant in the demo

The console's **Explain** and **Draft with AI** work in the container too. By default they answer with rules
(`DemoClient`, labelled *Demo (rules, no AI)*): no model, no download. To run a real local model as well:

```bash
docker compose --profile ai up --build       # first run: pulls the Ollama image (~3.4 GB) and the model (~1.9 GB)
DEMO_AI_MODEL=qwen3:4b-instruct-2507-q4_K_M docker compose --profile ai up --build    # the bigger model (12+ GB RAM)
```

The profile adds two containers. `ollama` runs Ollama with its models in the `ollama-models` volume, and
`ollama-pull` downloads the model once and exits. The console finds Ollama at `http://ollama:11434` through
`DEMO_OLLAMA_URL`. Without the profile that host does not exist, so the assistant answers with rules, and the panel
says how to turn the model on.

- **Private by construction.** The `ollama` container publishes **no port**. Only the demo container can reach it,
  on the compose network, so incident data never leaves the machine. Strictly, `ollama` is not `localhost` to the
  console, so the demo sets `allow_remote` for that one URL (invariant 5); the settings file is not changed.
- **Pinned.** `ollama/ollama:0.40.19`, the version the evaluation ran on. `OLLAMA_IMAGE_TAG` overrides it.
- **Sized for 8 GB machines.** The default model is `qwen2.5:3b`, the assistant's fallback model. In a check on a
  7.2 GB laptop (Docker's VM had 3.4 GB), the `ollama` container used 2.2 GB and Explain answered in two model
  calls. That answer also showed why the number check exists: the small model wrote "for 1 day" about an incident
  a few minutes old, and the check flagged the 1 as untraced. The evaluation in [docs/eval/](eval/README.md)
  measures the bigger model.
- `python docker/smoke_test.py --ai` checks this setup: the assistant uses the container's model and an Explain
  run completes on it. CI does not run it (it would download several GB on every push).

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
- the document totals come from the real CSV, and the file-size document is reported;
- the console is read-only and in demo mode, and refuses the banner's Stop monitoring;
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
