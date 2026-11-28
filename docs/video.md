# The video

A 1:51 recording of the real console with a real model: `qwen3:4b-instruct-2507` (Q4_K_M), running
in Ollama on a laptop (AMD Ryzen 5 7520U, 7.2 GB of RAM, no GPU). On the left is the console. On
the right, an "Under the hood" panel shows the code behind each step and the data that passed
through it. It was recorded in two passes (see *Is it real?*).

## What it shows

| Time | Step | What to notice |
|---|---|---|
| 0:00 | Title | |
| 0:06 | One JSON file | `monitoring_settings.json`: what to watch, the thresholds, the actions and the runbooks. Notepad is the demo process. |
| 0:12 | The pieces | Five PowerShell monitors write state files; the console only reads them. |
| 0:17 | Notepad closes | The recorder closes its own Notepad. The process monitor notices on its next check (a 5 s wait, labelled). |
| 0:19 | One incident | The incident record from `GET /api/status`, written by the monitor (`ConvertTo-IncidentRecord`): id, level, start time. |
| 0:28 | Explain | On the critical budget incident (the CSV was edited as `docs/test-environment.md` shows: $408.15, 102 % of $400). Four tools, all read-only. |
| 0:34 | The grounding gate | The model answered before reading anything. The console did not accept that answer: it read the incident and the runbook itself and asked again. |
| 0:40 | `get_incident` | The tool's result as the model got it: value, threshold, unit, the current reading, whether the monitor is alive. |
| 0:47 | `get_runbook` | The runbook text of the critical threshold. |
| 0:54 | The check | Every number in the answer (408.15, 400, 102) is in a tool result. |
| 1:05 | The ticket | The budget alert's `email_draft` opened ticket INC0010001. Priority 1 - Critical comes from the rules. |
| 1:11 | Draft with AI | The model reads the incident, the log and the runbook, and writes three text fields. |
| 1:18 | The draft | The model wrote the short description, description and work notes; impact, urgency, priority, category and group are the rules' (`code_fields`). |
| 1:29 | The email | Still a draft: nothing is sent until you open it in your mail app. |
| 1:33 | Evaluation | The published reports: 21 scenarios; rules 19, qwen3:4b 17 and 16; grounding, ticket fields, injection and side effects held in every run. |
| 1:39 | End | |

## Is it real?

- **The model is real, and it ran alone first.** On a 7.2 GB laptop the model and the recording
  browser do not fit in memory together: the first attempt timed out loading the model, and the
  rules answered instead (labelled as such); the second crashed the recorder. So the take was
  recorded in two passes, as in luna-hybrid-agent (its decision 0043). In the first pass
  (`video/pass1.mjs`) the model ran Explain and Draft with AI on the same scratch copy and data,
  with no browser. In the second, the console replayed those turns while the take was recorded;
  the tools, the grounding gate, the number check and the ticket fields ran again. The take fails
  unless every model turn, the answer, the ticket and the check equal the first pass, and this
  one matched.
- **Every wait is labelled, with its real length.** The model's five calls took 58, 32, 9, 29 and
  28 s in the first pass; each shows for 1 s with that length. The process monitor's wait (5 s)
  is cut to 1 s, also labelled.
- **One kind of answer is set aside.** An answer that quotes a clock time cannot be replayed
  truthfully (the take's incident opens at another time). The first pass runs a task again when
  that happens, up to three times; this take needed one try for each task. The unfiltered measure
  of the model is the evaluation in [docs/eval/](eval/README.md).
- **The panel shows captured data.** Each payload is what the console's API returned during the
  take: the incident from `GET /api/status`, and the tool results, the check and the ticket from
  `GET /api/ai/runs/{id}`. `video/cues.mjs` compares each one with the capture again (5 of 5) and
  checks that no local path appears. Code excerpts are found by file and symbol
  (`video/lines.mjs`), so their line numbers are the current ones.
- **The rest is the real product.** The monitors run from a clean scratch copy
  (`start_monitoring.bat video`): the budget alert, its popup and its ticket happened. The
  computer name is set to `WSM-DEMO` for the copy.

**Known in this take: two of the model's mistakes, kept, not re-rolled.**

- The explanation says the budget "exceeded its target by 102%". The spend is *at* 102 % of the
  target, so 2 % over it. Every number in that sentence is in the data (102, 408.15, 400), so the
  check passes it: it checks where a number comes from, not what the sentence says about it.
- The ticket's description says "No errors or duplicates were found in the log data". The log
  cannot show that; it is the model's inference. Its "2% overspend" is its own arithmetic
  (102 % - 100 %), and the check passes the 2 because a 2 appears in the data.

These are the limits the evaluation also reports ([docs/eval/](eval/README.md)). They are why the
ticket's priority and the actions never come from the model, and why the answer is a draft for
a person to read.

The ending shows the email step in the console's ticket rather than a desktop recording of a mail
client: the plan's desktop ending was left out to keep the take reliable on this machine.

## Record it again

See [video/README.md](../video/README.md). In short:

```bash
cd video && npm ci
node pass1.mjs                  # the model alone: out/ollama/script-pass1.json
npm run video:ollama            # the take, replaying it; then the checks and ffmpeg
```

The output in `video/out/ollama/` is `video.mp4`, `video-readme.mp4` (1280x720, under 10 MB, for
the README), `poster.png`, `subtitles.en.srt`, and `take.json` with the first-pass timings and the
match. `npm run video:dry` rehearses the take on a scripted model.
