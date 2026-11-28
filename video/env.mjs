/**
 * The take's environment: the real monitors from a clean scratch copy (start_monitoring.bat video,
 * scripts/video_mode.ps1), never the project's own logs or settings. Windows only.
 */
import { execFileSync, spawn, spawnSync } from 'node:child_process'
import { readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

export const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
export const COPY = join(process.env.TEMP ?? tmpdir(), 'wsm-video')
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

function ps(file, env = {}) {
  return spawnSync('powershell.exe', ['-ExecutionPolicy', 'Bypass', '-NoProfile', '-NonInteractive', '-File', file], {
    env: { ...process.env, ...env }, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 180_000,
  })
}

async function portsFree(timeoutMs) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const busy = await Promise.all([5757, 5758].map((p) => fetch(`http://localhost:${p}/`).then(() => true, () => false)))
    if (!busy.some(Boolean)) return
    await sleep(1000)
  }
}

/** Notepad PIDs running now: the take needs none of the user's own. */
export function notepadPids() {
  const out = execFileSync('tasklist', ['/FI', 'IMAGENAME eq notepad.exe', '/FO', 'CSV', '/NH'], { encoding: 'utf8' })
  return [...out.matchAll(/"notepad\.exe","(\d+)"/gi)].map((m) => Number(m[1]))
}

/** Starts a Notepad of the take's own; returns its PID (only that one is closed later). */
export async function startNotepad() {
  const before = new Set(notepadPids())
  spawn('notepad.exe', [], { detached: true, stdio: 'ignore' }).unref()
  for (let i = 0; i < 40; i++) {
    await sleep(250)
    const mine = notepadPids().filter((p) => !before.has(p))
    if (mine.length) return mine[0]
  }
  throw new Error('Notepad did not start')
}

export function closeNotepad(pid) {
  spawnSync('taskkill', ['/PID', String(pid), '/F'], { stdio: 'ignore' })
}

/**
 * Starts video mode (fresh copy, assistant on). `script`: a model script (dry takes) or none (the
 * real model). COMPUTERNAME is set for the copy so no real computer name reaches the video.
 */
export async function startEnv({ script = '', model = '' } = {}) {
  await portsFree(20_000)
  const env = { NO_BROWSER: '1', COMPUTERNAME: 'WSM-DEMO', WSM_AI_SCRIPT: script }
  const args = model ? ['-Model', model] : []
  const run = spawnSync('powershell.exe', ['-ExecutionPolicy', 'Bypass', '-NoProfile', '-NonInteractive', '-File',
    join(ROOT, 'scripts', 'video_mode.ps1'), ...args], { env: { ...process.env, ...env }, encoding: 'utf8', timeout: 240_000 })
  if (run.status !== 0) throw new Error(`video mode did not start:\n${run.stdout}\n${run.stderr}`)
}

export function stopEnv() {
  if (process.env.VIDEO_KEEP_RUNNING) return
  ps(join(COPY, 'scripts', 'stop_monitoring.ps1'))
}

/** The test guide's own example (docs/test-environment.md), in the COPY's CSV: the groceries
 * budget goes critical (102 %), which opens ticket INC0010001. */
export function makeBudgetCritical() {
  const csv = join(COPY, 'sample_data', 'monthly_budget_sample.csv')
  const text = readFileSync(csv, 'utf8')
  const edited = text.replace('Groceries,Fruit and vegetables,22.00', 'Groceries,Fruit and vegetables,90.00')
  if (edited === text) throw new Error('the Groceries row to edit was not found in the copy')
  writeFileSync(csv, edited, 'utf8')
}

/** The last run traces of the copy (the console writes them; the take saves the ones it used). */
export function traceFile(runId) {
  return join(COPY, 'logs', 'ai_traces', `${runId}.json`)
}
