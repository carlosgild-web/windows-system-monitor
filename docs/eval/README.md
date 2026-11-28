# Evaluating the incident assistant

How well does a small local model explain an incident, and do the guardrails hold when it doesn't? This
folder holds the reports of `eval/assistant_eval.py`, failures included. Design: section 12 of
[design-decisions.md](../design-decisions.md).

## Results

| Run | Client | Passed | Report |
|---|---|---|---|
| Reference | a scripted model that reads the data and answers well (CI requires 100 %) | 21 of 21 | `python eval/assistant_eval.py` |
| Baseline | rules, no AI (`DemoClient`): what you get without Ollama | 19 of 21 | [rules baseline](2026-11-28-rules-baseline-no-AI.md) |
| Model, run 1 | qwen3:4b-instruct-2507 (Q4_K_M), local, CPU only | 17 of 21 | [run 1](2026-11-28-qwen3-4b-instruct-2507-q4-K-M-run1.md) |
| Model, run 2 | the same model, after the fixes below | 16 of 21 | [run 2](2026-11-28-qwen3-4b-instruct-2507-q4-K-M.md) |

Machine: a laptop with an AMD Ryzen 5 7520U, 7.2 GB of RAM and integrated graphics, so the model runs on the
CPU. A run takes about 50 seconds (median), at most 85.

**What held every time, on the real model, in both runs:** every answer was grounded in the incident and its
runbook (20 of 20), every ticket kept the priority, impact, urgency and category the rules set (7 of 7), no
run changed a file (21 of 21), and none of the four prompt injections (a process name, a document value, a log
line, a request to set priority 5) was obeyed. These are the properties the code enforces: the grounding gate,
the read-only tools, the code-owned ticket fields.

**What the model gets wrong:** these depend on the model, and they move between runs.

| Failure | Run 1 | Run 2 |
|---|---|---|
| Leaves out the threshold (the "85" of an 87.9 % memory warning, the "95" of a memory ticket) | 1 | 2 |
| Does not say that there is no runbook | 2 | 2 |
| Writes a number that is not in the data ("8.8", from 8.8.8.8, a DNS server it suggests on its own) | 0 | 1 |
| Answers a Spanish request in English | 1 | 0 |

And one that the scoring cannot see: in run 2 the memory ticket says "if memory remains above 96.5 %, escalate".
96.5 is the current value, not the threshold (95). The number is in the data, so the number check passes. It
checks where a number comes from, not what it is called. The same thing happened before `value_unit` existed:
"the warning threshold of $80" for a threshold of 80 % of the target.

The model called `get_incident` by itself in 11 of 20 runs. In the other 9 it answered first, and the console made
the reads for it (the grounding gate). Without the gate, those 9 answers would have been guesses with no numbers
in them, and nothing else would have caught them.

## What the evaluation changed

Each finding below came from a run on the real model, and each fix has a test:

1. **Grounding gate** (`agent.py`): qwen3:4b sometimes answered on its first call without reading anything, and
   when asked to read first it invented an incident id (`doc-12345`). The console now makes the missing reads
   itself and asks again.
2. **Units** (`get_incident` returns `value_unit`): "threshold $80" for a threshold of 80 % of the target.
3. **Stale data** (`get_incident` adds a sentence when the monitor is stale): the boolean `monitor_stale: true`
   was ignored; a sentence was read.
4. **No runbook** (`get_runbook` says so in a sentence instead of a bare `null`), and the **language** instruction
   is now in the system prompt too. Run 2 fixed the Spanish answers (2 of 2, from 1 of 2) and the budget ticket's
   missing runbook note; the console-port ticket still left it out, and the log-size scenario, which passed in
   run 1, now left it out too. At this model size each such fix moves a scenario or two, and the answers shift
   from run to run.
5. **A bug in the number check**, found in run 2: tool results were scanned as JSON text, where a new line becomes
   the two characters `\n`; the `n` hid a step number at the start of a runbook line, so "2." was reported as
   untraced. Re-checked with the fix, the run 2 memory ticket has no untraced numbers; it still fails on the
   missing threshold, so run 2 stays at 16 of 21.

## How to run it

```text
python eval/assistant_eval.py                       # reference script (what CI runs, via tests/python/test_eval.py)
python eval/assistant_eval.py --client rules        # the rules baseline
python eval/assistant_eval.py --client ollama --report docs/eval/ --note "machine..."
```

The Ollama run uses `ai.model` from the settings (or `--model`) and needs Ollama running. `--only` takes a comma
list of scenario ids. Each scenario builds a throw-away project with one open incident; nothing in `logs/` is
touched.
