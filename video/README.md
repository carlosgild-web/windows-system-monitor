# The README video

Records "a real model, under the hood" from the running console. Ported from
`hl-bead-studio/video/` (the portfolio's reference): the stage, cues, compose and desktop-capture
modules, with a recorder and a storyboard of its own. Dev-only: not part of the runtime, the
Docker image or CI. Windows only (the real monitors), with ffmpeg on the `PATH` and, for the real
take, Ollama with the model pulled.

```bash
cd video && npm ci          # @playwright/test only
npm run video:check         # every [file, symbol] in storyboard-ollama.json still resolves
npm run video:test          # how compose.mjs cuts a take; the honesty checks of cues.mjs
npm run video:smoke         # ~30 s: the 1920x1080 stage -> out/smoke/
npm run video:dry           # the whole take on the scripted model (script-dry.json) -> out/dry/
node pass1.mjs              # first pass: the real model alone -> out/ollama/script-pass1.json
npm run video:ollama        # the take, replaying the first pass -> out/ollama/
```

The published take is recorded in **two passes** (F7): `pass1.mjs` runs Explain and Draft with AI
on the real model with no browser; the take then replays those model turns
(`MonitoringConsole/ai/scripted.py`, labelled "replayed from the first pass") while the tools,
the gate, the number check and the ticket fields run again, and fails unless the turns, the
answer, the ticket and the check equal the first pass. Each model wait shows for 1 s with its
first-pass length (`compose.mjs`, `real_s`).

Each take starts the monitors itself from a clean scratch copy (`start_monitoring.bat video`,
`%TEMP%\wsm-video`) and stops them at the end: the project's own settings and logs are never used.
It opens a Notepad of its own and closes only that one (close your own Notepad first: the monitor
matches by name), and it makes the budget critical in the copy's CSV for the ticket scene.
The copy's computer name is `WSM-DEMO`, so the real one never reaches the video.

## Files

| File | Role |
|---|---|
| `storyboard-ollama.json` | The rows: subtitle, layer, callouts, payload, the event that shows them |
| `record.spec.ts` | The takes (`@smoke`, `@dry`, `@ollama`): environment, capture, scenes |
| `env.mjs` | Video mode, the take's own Notepad, the budget edit, stopping the copy |
| `stage.html`, `stage.js` | Console iframe, "Under the hood" panel, subtitles, slides |
| `lines.mjs` | `file:symbol` → current line and excerpt (Python, PowerShell, JSON, JS/HTML) |
| `cues.mjs` | Cues, and the checks: payloads equal the capture, rows, no local paths |
| `compose.mjs` | Wait cuts with labels, `.mp4`, `.srt`, the README copy (ffmpeg) |
| `desktop.mjs`, `cues-desktop.json` | Desktop capture of a window (for the ending), and its subtitles |
| `script-dry.json` | The dry take's model turns (the scripted client) |

## Findings (dry takes, B4, 2026-11-28)

Three dry takes on the scripted model before the real one. No product code changed; every fix is in
the storyboard or the dry script.

| # | Finding | Kind | Fix |
|---|---|---|---|
| F1 | Explaining Notepad gives an answer with no numbers, so the "every number is checked" row showed an empty check | Storyboard | Explain runs on the critical budget incident ($408.15, 102 %, a runbook), the same one the ticket scene drafts; the Notepad scene shows a monitor opening one incident |
| F2 | 89.9 s, short of the standard's 2:15-2:45 | Tooling | Hold factor 0.6 -> 0.95 (106.8 s on the scripted model; the real model's waits, the grounding-gate row and a generic row add to it) |
| F3 | The strict check failed when the dry script called `get_recent_events` before `get_runbook` in one turn (rows 3.4 before 3.3) | Script | The dry script follows the storyboard's order; the real take is flexible |
| F4 | Waits: the process monitor's next check (8-30 s) and the document monitor's are cut to 1 s with their real length in the label | Expected | None |
| F5 | Real readings show up (a CPU spike to 100 % during a take) | Expected | None: it is the real console |

## Findings (the real take, B5, 2026-11-28)

| # | Finding | Kind | Fix |
|---|---|---|---|
| F6 | Take 1: loading the model from cold while the browser and the recorder shared the CPU took over `ai.timeout_sec` (90 s); the console handed Explain to the rules, as designed, and labelled it | Expected (product) | The take fails if a run is not the model's; the model is loaded before the take. On a slow machine, raise `ai.timeout_sec` |
| F7 | Take 2: the recorder crashed (exit `0xC0000409`) with 0.6 GB of RAM free: the model, Docker Desktop's VM and the recording browser did not fit in 7.2 GB | Machine | Two passes, as in luna-hybrid-agent (its decision 0043): `pass1.mjs` runs the model alone, the take replays it and must match it |
| F8 | A first-pass ticket quoted the incident's clock time ("since 10:54:57"); the take's incident opened at another time, so the replay would show a wrong time (the take's live check flagged it) | Two-pass limit | `pass1.mjs` sets aside a run that quotes a clock time or a date and runs it again (at most 3 tries; `take.json` records them). The evaluation stays the unfiltered measure |
| F9 | A replayed model step answers at once, so its labelled wait was 0 s long and ffmpeg failed | Tooling | The take holds 1.5 s on each replayed model step; `compose.mjs` skips pieces too short to encode |

The published take: 1:51, five model calls (58, 32, 9, 29 and 28 s in the first pass, each try 1),
16 rows (3.4 never matched: the model did not ask for the log in Explain), 5 of 5 payloads equal
the capture, no local paths, and every turn, the answer, the ticket and the check equal the first
pass. Two of the model's mistakes are in it and are named in docs/video.md.

Checked in every dry take: the payloads on screen equal the capture (6 of 6), no local path in any
payload or in the console's text, the computer name is `WSM-DEMO`, and the project's own logs and
settings are untouched.
