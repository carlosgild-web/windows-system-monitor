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
npm run video:ollama        # the take on the real local model -> out/ollama/
```

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

Checked in every dry take: the payloads on screen equal the capture (6 of 6), no local path in any
payload or in the console's text, the computer name is `WSM-DEMO`, and the project's own logs and
settings are untouched.
