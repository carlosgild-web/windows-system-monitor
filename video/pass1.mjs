/**
 * The first pass of the real take (decision 0043 in luna-hybrid-agent, reused here): on a 7.2 GB
 * laptop the model and the recording browser do not fit together (B5 F7). So the model runs alone
 * first, on the same scratch copy and data as the take, with no browser and no recorder:
 *
 *   node pass1.mjs            -> out/ollama/pass1-explain.json, pass1-ticket.json, script-pass1.json
 *
 * Then `npm run video:ollama` records the take while the console replays these turns
 * (ai/scripted.py), and the take fails unless every model turn, the answer and the ticket equal
 * this pass. The tools, the grounding gate, the number check and the ticket fields run live again.
 */
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { makeBudgetCritical, sleep, startEnv, stopEnv } from './env.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const OUT = join(HERE, 'out', 'ollama')
const BASE = 'http://localhost:5758'
const OLLAMA = 'http://localhost:11434'
const BUDGET = 'document:Groceries spend (monthly budget):critical'

const get = async (path) => (await fetch(BASE + path)).json()
const post = async (path, body) => {
  const r = await fetch(BASE + path, { method: 'POST', headers: { 'Content-Type': 'application/json', Origin: BASE }, body: JSON.stringify(body) })
  return { status: r.status, body: await r.json() }
}

async function until(what, fn, timeoutMs) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (await fn().catch(() => false)) return
    await sleep(1000)
  }
  throw new Error(`timed out waiting for ${what}`)
}

// B5 F8: a run whose text quotes a clock time or a date cannot be replayed truthfully: the
// take's incident opens at another time. Such a run is set aside and the task runs again (at
// most TRIES times); script-pass1.json records the tries. The evaluation (docs/eval/) is the
// unfiltered measure of the model.
const TRIES = 3
const CLOCK = /\b\d{1,2}:\d{2}(?::\d{2})?\b|\b\d{4}-\d{2}-\d{2}\b/
const textOf = (r) => (r.ticket ? [r.ticket.short_description, r.ticket.description, r.ticket.work_notes].join('\n') : r.answer || '')

async function runReplayable(route, task) {
  for (let i = 1; i <= TRIES; i++) {
    const r = await run(route, task)
    const hit = textOf(r).match(CLOCK)
    if (!hit) return { run: r, tries: i }
    console.log(`${task}: try ${i} quotes "${hit[0]}"; not replayable, running it again`)
  }
  throw new Error(`${task}: every try quoted a clock time`)
}

async function run(route, task) {
  const started = await post(`/api/ai/${route}`, { incident_id: BUDGET })
  if (started.status !== 202) throw new Error(`${route}: HTTP ${started.status} ${JSON.stringify(started.body)}`)
  let r
  await until(`the ${task} run`, async () => (r = (await get(`/api/ai/runs/${started.body.run_id}`)).run).status !== 'running', 10 * 60_000)
  if (r.status !== 'done') throw new Error(`${task}: ${r.status} ${r.error}`)
  if (r.client.kind !== 'ollama') throw new Error(`${task} was answered by ${r.client.label}: ${r.client.reason}`)
  return r
}

/** The model's turns, in order, as ai/scripted.py replays them; and how long each call took. */
export function turnsOf(trace) {
  const turns = []
  const seconds = []
  let prev = Date.parse(trace.started.replace(' ', 'T'))
  for (const s of trace.steps) {
    if (s.type !== 'model') continue
    const at = Date.parse(s.at.replace(' ', 'T'))
    seconds.push(Math.max(1, Math.round((at - prev) / 1000)))
    prev = at
    turns.push(s.tool_calls.length ? { tool_calls: s.tool_calls.map((c) => ({ name: c.name, arguments: c.arguments })) } : { content: s.content })
  }
  return { turns, seconds }
}

async function main() {
  mkdirSync(OUT, { recursive: true })
  await startEnv()
  try {
    makeBudgetCritical()
    const ai = (await get('/api/ai/status')).client
    if (ai.kind !== 'ollama') throw new Error(`pass 1 needs Ollama: ${ai.reason}`)
    console.log(`pass 1 on ${ai.model}: loading it...`)
    const t = Date.now()
    await fetch(`${OLLAMA}/api/generate`, { method: 'POST', body: JSON.stringify({ model: ai.model, prompt: '', keep_alive: '10m' }) })
    const warm = Math.round((Date.now() - t) / 1000)
    await until('the budget incident', async () => (await get('/api/status')).incidents.some((i) => i.id === BUDGET), 120_000)
    const { run: explain, tries: explainTries } = await runReplayable('explain', 'explain')
    console.log(`explain: ${explain.usage.model_calls} model calls, check ok=${explain.check.ok}, try ${explainTries}`)
    const { run: ticket, tries: ticketTries } = await runReplayable('ticket-draft', 'ticket')
    console.log(`ticket: ${ticket.usage.model_calls} model calls, priority ${ticket.ticket.priority}, try ${ticketTries}`)
    writeFileSync(join(OUT, 'pass1-explain.json'), JSON.stringify(explain, null, 2))
    writeFileSync(join(OUT, 'pass1-ticket.json'), JSON.stringify(ticket, null, 2))
    const e = turnsOf(explain)
    const k = turnsOf(ticket)
    writeFileSync(join(OUT, 'script-pass1.json'), JSON.stringify({
      _comment: 'Written by pass1.mjs: the real model\'s turns of the first pass, replayed during the recording.',
      delay_sec: 1.2,
      model: ai.model,
      label: `${ai.model} (replayed from the first pass)`,
      reason: `Recorded in two passes: ${ai.model} ran alone first, on this PC; this take replays its turns. The tools, the checks and the ticket fields run again.`,
      warmup_s: warm,
      tries: { explain: explainTries, ticket: ticketTries },
      seconds: { explain: e.seconds, ticket: k.seconds },
      explain: e.turns,
      ticket: k.turns,
    }, null, 2))
    console.log(`script-pass1.json: explain ${e.seconds.join('+')} s, ticket ${k.seconds.join('+')} s (model load ${warm} s)`)
  } finally {
    stopEnv()
    // Free the memory for the recording pass.
    const ai = await fetch(`${OLLAMA}/api/ps`).then((r) => r.json()).catch(() => ({ models: [] }))
    for (const m of ai.models ?? []) {
      await fetch(`${OLLAMA}/api/generate`, { method: 'POST', body: JSON.stringify({ model: m.name, keep_alive: 0 }) }).catch(() => {})
    }
  }
}

main().catch((err) => {
  console.error(`pass 1 failed: ${err.message}`)
  process.exit(1)
})
