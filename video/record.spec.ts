/**
 * The README video take (ported from hl-bead-studio/video). Starts the real monitors from a clean
 * scratch copy (video mode), drives the real console inside the 1920x1080 stage, and shows each
 * storyboard row when its captured event arrives.
 *
 *   npm run video:smoke    the stage layout at 1920x1080 (~1 min with the start-up)
 *   npm run video:dry      the whole take on the scripted model (script-dry.json): strict mode
 *   npm run video:ollama   the take on the real local model (Ollama): the published video
 *
 * Capture: the console is not changed. The recorder routes POST /api/ai/explain and
 * /api/ai/ticket-draft (to learn the run id) and reads GET /api/status and GET
 * /api/ai/runs/{id} itself, so every payload on screen is the server's own data (events.json).
 */
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, renameSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { expect, test, type APIRequestContext, type Browser, type FrameLocator, type Page } from '@playwright/test'

import { hasLocalPath, pick } from './cues.mjs'
import { closeNotepad, COPY, makeBudgetCritical, notepadPids, ROOT, sleep, startEnv, startNotepad, stopEnv, traceFile } from './env.mjs'
import { resolve as resolveLine } from './lines.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const STAGE = { width: 1920, height: 1080 }
const BOARD_FILE = 'storyboard-ollama.json'
const NOTEPAD = 'process:notepad.exe:warning'
const BUDGET = 'document:Groceries spend (monthly budget):critical'
const TICKET = 'INC0010001'
const RUN_TIMEOUT_MS = 8 * 60_000
// Generic rows (tool calls the storyboard did not foresee) shown at most.
const MAX_GENERIC = Number(process.env.VIDEO_MAX_GENERIC ?? 1)
// A subtitle stays at least this long per character (hl-bead-studio F13).
const READ_MS_PER_CHAR = 1000 / 17
const PATH_RE = /(?<![A-Za-z])[A-Za-z]:\\[^\s\\]|\\Users\\|\/home\/|MyData|AppData/

type Row = {
  id: string
  scene: number
  subtitle: string
  layer?: string
  slide?: string
  optional?: boolean
  on?: { event: string; task?: string; name?: string }
  payload?: { label: string; pick?: string }
  callouts?: string[][]
}
type Board = { video: string; banner: string; mode?: 'strict' | 'flexible'; hold?: number; rows: Row[] }
type Captured = { type: string; data: any; t_ms: number; task: string | null; index: number }

const loadBoard = (): Board => JSON.parse(readFileSync(join(HERE, BOARD_FILE), 'utf8'))

function holdMs(row: Row, factor = 1) {
  const chars = (row.subtitle || '').length
  const paced = (Math.min(Math.max(1400 + chars * 48, 2800), 8500) + (row.payload ? 1800 : 0)) * factor
  return Math.round(Math.max(paced, chars * READ_MS_PER_CHAR))
}

/** The evaluation slide's numbers, from the published reports (docs/eval/*.json). */
function evalSlide() {
  const dir = join(ROOT, 'docs', 'eval')
  const runs = readdirSync(dir).filter((f) => f.endsWith('.json')).sort().map((f) => {
    const results = JSON.parse(readFileSync(join(dir, f), 'utf8'))
    const passed = results.filter((r: any) => r.passed).length
    const label = f.includes('rules') ? 'Rules, no AI' : `qwen3:4b, ${f.includes('run1') ? 'run 1' : 'run 2'}`
    return { label, passed: `${passed} of ${results.length}`, held: 'grounding, ticket fields, injection, no side effects', order: f.includes('rules') ? 0 : f.includes('run1') ? 1 : 2 }
  }).sort((a, b) => a.order - b.order)
  return { scenarios: 21, runs }
}

class Conductor {
  events: Captured[] = []
  shown: Array<{ id: string; t_ms: number; hold_ms: number; subtitle: string; payload?: unknown; source?: unknown }> = []
  waits: Array<{ from_ms: number; to_ms: number; what: string }> = []
  shownIds = new Set<string>()
  generic = 0
  skippedGeneric: string[] = []
  runs: Record<string, any> = {}

  constructor(readonly page: Page, readonly board: Board, readonly t0: number) {}

  now() {
    return Date.now() - this.t0
  }

  capture(type: string, data: any, task: string | null = null) {
    const ev = { type, data, t_ms: this.now(), task, index: this.events.length }
    this.events.push(ev)
    return ev
  }

  rowFor(ev: Captured) {
    return this.board.rows.find((r) => r.on && r.on.event === ev.type && (!r.on.task || r.on.task === ev.task)
      && (!r.on.name || r.on.name === ev.data?.name) && !this.shownIds.has(r.id))
  }

  async show(id: string, ev?: Captured) {
    const row = this.board.rows.find((r) => r.id === id)!
    this.shownIds.add(row.id)
    const callouts = (row.callouts ?? []).map(([file, symbol]) => resolveLine(file, symbol))
    let payload
    if (row.payload) {
      if (!ev) throw new Error(`row ${row.id}: a payload row needs its captured event`)
      const value = pick(ev.data, row.payload.pick)
      if (value === undefined) throw new Error(`row ${row.id}: "${row.payload.pick}" not in the captured ${ev.type}`)
      if (hasLocalPath(value)) throw new Error(`row ${row.id}: the payload shows a local path`)
      payload = { label: row.payload.label, note: row.payload.pick ? `.${row.payload.pick}` : 'captured', value,
        source: { index: ev.index, pick: row.payload.pick } }
    }
    const slideData = row.slide === 'end'
      ? { repo: process.env.VIDEO_REPO_URL || 'github.com/carlosgild-web/windows-system-monitor',
          author: process.env.VIDEO_AUTHOR ?? 'Carlos Velazquez', linkedin: process.env.VIDEO_LINKEDIN ?? 'linkedin.com/in/carlos-v-90b99149' }
      : row.slide === 'eval' ? evalSlide() : undefined
    await this.page.evaluate((c) => (window as any).stage.show(c), {
      id: row.id, subtitle: row.subtitle, layer: row.layer, callouts, payload, slide: row.slide, slideData,
    })
    const hold = holdMs(row, this.board.hold)
    this.shown.push({ id: row.id, t_ms: this.now(), hold_ms: hold, subtitle: row.subtitle, payload: payload?.value, source: payload?.source })
    await sleep(hold)
  }

  /** A tool call the storyboard did not foresee (a real model's choice). */
  async showGeneric(ev: Captured) {
    if (this.generic >= MAX_GENERIC) {
      this.skippedGeneric.push(`${ev.type} ${ev.data?.name ?? ''}`)
      return
    }
    this.generic++
    const id = `g${this.generic}`
    const subtitle = `It also calls ${ev.data.name}: another read-only tool.`
    await this.page.evaluate((c) => (window as any).stage.show(c), {
      id, subtitle, layer: 'Tools', callouts: [],
      payload: { label: `tool result: ${ev.data.name}`, note: '.result', value: ev.data.result },
    })
    const hold = holdMs({ id, scene: 0, subtitle, payload: { label: '' } }, this.board.hold)
    this.shown.push({ id, t_ms: this.now(), hold_ms: hold, subtitle, payload: ev.data.result, source: { index: ev.index, pick: 'result' } })
    await sleep(hold)
  }

  async onEvent(ev: Captured, allowGeneric: boolean) {
    const row = this.rowFor(ev)
    if (row) await this.show(row.id, ev)
    else if (allowGeneric && ev.type === 'tool') await this.showGeneric(ev)
  }

  missing() {
    return this.board.rows.filter((r) => !this.shownIds.has(r.id)).map((r) => r.id)
  }
}

async function openStage(browser: Browser, outDir: string) {
  const context = await browser.newContext({ baseURL: 'http://localhost:5758', viewport: STAGE,
    recordVideo: { dir: join(outDir, 'raw'), size: STAGE } })
  await context.route('**/__video/*', (route) => {
    const name = new URL(route.request().url()).pathname.split('/').pop()!
    if (!['stage.html', 'stage.js'].includes(name)) return route.fulfill({ status: 404 })
    return route.fulfill({ path: join(HERE, name), contentType: name.endsWith('.js') ? 'text/javascript' : 'text/html' })
  })
  // The console's portfolio banner and its pill stay out of the video.
  await context.addInitScript(() => {
    if (location.pathname.startsWith('/__video')) return
    try { localStorage.setItem('wsm-demo-guide', 'pill') } catch { /* not remembered */ }
    document.addEventListener('DOMContentLoaded', () => {
      const s = document.createElement('style')
      s.textContent = '.guide-pill { display: none !important; }'
      document.head.appendChild(s)
    })
  })
  const t0 = Date.now()
  const page = await context.newPage()
  await page.goto('/__video/stage.html')
  return { context, page, app: page.frameLocator('#app'), t0 }
}

async function loadApp(page: Page, path = '/') {
  await page.evaluate((p) => (window as any).stage.loadApp(p), path)
}

async function assertNoPaths(page: Page, where: string) {
  const text: string = await page.evaluate(() => (window as any).stage.appText())
  const hit = text.match(PATH_RE)
  if (hit) throw new Error(`${where}: a local path is visible in the console ("${hit[0]}")`)
}

async function openIncidents(api: APIRequestContext) {
  const status = await (await api.get('/api/status')).json()
  return (status.incidents ?? []) as any[]
}

/** Runs one assistant task by clicking in the console, and captures the run's steps as they come. */
async function followRun(cond: Conductor, page: Page, api: APIRequestContext, task: 'explain' | 'ticket', click: () => Promise<void>, allowGeneric: boolean) {
  const route = task === 'explain' ? '**/api/ai/explain' : '**/api/ai/ticket-draft'
  let runId = ''
  await page.context().route(route, async (r) => {
    const response = await r.fetch()
    runId = (await response.json()).run_id ?? ''
    await r.fulfill({ response })
  })
  await click()
  await expect.poll(() => runId, { timeout: 30_000 }).not.toBe('')
  await page.context().unroute(route)
  await cond.onEvent(cond.capture('request', { task, run_id: runId }, task), false)
  let seen = 0
  const deadline = Date.now() + RUN_TIMEOUT_MS
  let run: any
  for (;;) {
    run = (await (await api.get(`/api/ai/runs/${runId}`)).json()).run
    for (const step of run.steps.slice(seen)) {
      seen++
      if (step.type === 'tool') await cond.onEvent(cond.capture('tool', step, task), allowGeneric && task === 'explain')
      else if (step.type === 'note' && /answered before calling/.test(step.text)) await cond.onEvent(cond.capture('gate', step, task), false)
    }
    if (run.status !== 'running') break
    if (Date.now() > deadline) throw new Error(`the ${task} run did not finish`)
    await sleep(400)
  }
  cond.runs[task] = run
  await cond.onEvent(cond.capture('done', run, task), false)
  return run
}

async function saveTake(cond: Conductor, page: Page, outDir: string, extra: Record<string, unknown>) {
  writeFileSync(join(outDir, 'events.json'), JSON.stringify(cond.events, null, 2))
  writeFileSync(join(outDir, 'shown.json'), JSON.stringify(cond.shown, null, 2))
  writeFileSync(join(outDir, 'waits.json'), JSON.stringify(cond.waits, null, 2))
  for (const [task, run] of Object.entries(cond.runs)) writeFileSync(join(outDir, `trace-${task}.json`), JSON.stringify(run, null, 2))
  writeFileSync(join(outDir, 'take.json'), JSON.stringify({
    storyboard: BOARD_FILE, missing: cond.missing(), generic_skipped: cond.skippedGeneric,
    clients: Object.fromEntries(Object.entries(cond.runs).map(([t, r]) => [t, r.client])), ...extra,
  }, null, 2))
  const video = page.video()
  await page.context().close()
  if (video) {
    await video.saveAs(join(outDir, 'take.webm.part'))
    renameSync(join(outDir, 'take.webm.part'), join(outDir, 'take.webm'))
  }
}

// ---------------------------------------------------------------- the takes

test('smoke: the stage at 1920x1080 @smoke', async ({ browser, request }) => {
  const outDir = join(HERE, 'out', 'smoke')
  mkdirSync(outDir, { recursive: true })
  await startEnv()
  try {
    const board = loadBoard()
    const ai = (await (await request.get('/api/ai/status')).json()).client
    const { context, page } = await openStage(browser, outDir)
    await page.evaluate((b) => (window as any).stage.init(b), { banner: 'Smoke test: the stage layout', provider: `assistant: ${ai.label}` })
    await loadApp(page)
    await expect(page.frameLocator('#app').locator('#refresh-lbl')).toContainText('refreshed')
    const row = board.rows.find((r) => r.id === '3.2')!
    await page.evaluate((c) => (window as any).stage.show(c), {
      id: row.id, subtitle: row.subtitle, layer: row.layer, callouts: row.callouts!.map(([f, s]) => resolveLine(f, s)),
      payload: { label: 'GET /api/ai/status', note: 'captured', value: ai },
    })
    const box = async (sel: string) => page.locator(sel).boundingBox()
    expect(await box('#app')).toEqual({ x: 0, y: 0, width: 1280, height: 960 })
    expect(await box('#panel')).toEqual({ x: 1280, y: 0, width: 640, height: 960 })
    expect(await box('#subs')).toEqual({ x: 0, y: 960, width: 1920, height: 120 })
    expect(await page.evaluate(() => document.documentElement.scrollWidth > 1920 || document.documentElement.scrollHeight > 1080), 'the stage scrolls').toBe(false)
    expect(await page.evaluate(() => { const p = document.getElementById('pipeline')!; return p.scrollWidth <= p.clientWidth }), 'the pipeline fits').toBe(true)
    await assertNoPaths(page, 'smoke')
    await sleep(4000)
    await page.screenshot({ path: join(outDir, 'stage.png') })
    await page.evaluate(() => (window as any).stage.slide('map'))
    await sleep(3000)
    await page.screenshot({ path: join(outDir, 'slide-map.png') })
    const video = page.video()
    await context.close()
    await video?.saveAs(join(outDir, 'smoke.webm'))
  } finally {
    stopEnv()
  }
})

/**
 * The take: on the scripted model (a dry run, strict: every required row in order) or on the
 * real model through Ollama (the published video, flexible: a real model's steps vary).
 */
for (const [kind, tag] of [['dry', '@dry'], ['ollama', '@ollama']] as const)
  test(`${kind} take ${tag}`, async ({ browser, request }) => {
    const outDir = join(HERE, 'out', kind)
    mkdirSync(outDir, { recursive: true })
    if (notepadPids().length) throw new Error('Close Notepad first: the take closes its own Notepad, and the monitor matches by name')
    const board = loadBoard()
    const strict = kind === 'dry'
    if (strict) board.mode = 'strict'
    const notepad = await startNotepad()
    await startEnv({ script: strict ? join(HERE, 'script-dry.json') : '', model: process.env.VIDEO_MODEL ?? '' })
    try {
      makeBudgetCritical()
      const ai = (await (await request.get('/api/ai/status')).json()).client
      if (!strict && ai.kind !== 'ollama') throw new Error(`the real take needs Ollama: ${ai.reason}`)
      const { page, app, t0 } = await openStage(browser, outDir)
      const cond = new Conductor(page, board, t0)
      const banner = strict ? 'Dry take: scripted model (no AI)' : board.banner.replace('{model}', ai.model)
      await page.evaluate((b) => (window as any).stage.init(b), { banner, provider: strict ? 'tools, data and checks are real' : 'nothing leaves this PC' })

      // 0-1: the hook, the console and the config, the pieces.
      await cond.show('0.1')
      await loadApp(page)
      await expect(app.locator('#refresh-lbl')).toContainText('refreshed')
      await cond.show('1.1')
      await cond.show('1.2')
      await page.evaluate(() => (window as any).stage.hideSlide())
      await assertNoPaths(page, 'the console')

      // 2: Notepad closes; the process monitor opens one incident on its next check.
      closeNotepad(notepad)
      const closedAt = cond.now()
      await cond.show('2.1')
      let incident: any
      await expect.poll(async () => (incident = (await openIncidents(request)).find((i) => i.id === NOTEPAD)), { timeout: 120_000, intervals: [1000] }).toBeTruthy()
      cond.waits.push({ from_ms: closedAt, to_ms: cond.now(), what: "the process monitor's next check (every 30 s)" })
      await app.locator('body').evaluate(() => (window as any).fetchStatus())
      await cond.onEvent(cond.capture('incident', incident), false)

      // 3: Explain, on the model, with the run's steps as they happen.
      const row = app.locator('#inc-list .row', { hasText: 'notepad.exe' })
      await row.getByRole('button', { name: /Explain/ }).hover()
      await followRun(cond, page, request, 'explain', () => row.getByRole('button', { name: /Explain/ }).click(), !strict)
      await expect(app.locator('#ai-body .ai-answer')).toBeVisible()
      await sleep(2500)
      await app.locator('#ai-body').evaluate((el) => el.scrollTo({ top: el.scrollHeight, behavior: 'smooth' }))
      await sleep(2000)
      await assertNoPaths(page, 'the Explain panel')
      await app.locator('body').press('Escape')

      // 4: the budget's ticket (opened by its email_draft action), then Draft with AI.
      const ticketFile = join(COPY, 'logs', 'tickets', `${TICKET}.html`)
      const ticketWait = cond.now()
      await expect.poll(() => existsSync(ticketFile), { timeout: 120_000, intervals: [1000] }).toBe(true)
      if (cond.now() - ticketWait > 3000) cond.waits.push({ from_ms: ticketWait, to_ms: cond.now(), what: "the document monitor's next check" })
      expect((await openIncidents(request)).some((i) => i.id === BUDGET)).toBe(true)
      await loadApp(page, `/tickets/${TICKET}`)
      await cond.show('4.1')
      await app.locator('#ai-draft').hover()
      await followRun(cond, page, request, 'ticket', () => app.locator('#ai-draft').click(), false)
      await expect(app.locator('#ai-bar .ai-tag')).toBeVisible()
      await sleep(2500)
      await app.locator('#t-work-sec').scrollIntoViewIfNeeded()
      await sleep(1500)
      await assertNoPaths(page, 'the ticket')

      // 5: the email is a draft; 6-7: the evaluation and the end card.
      await app.getByRole('button', { name: /Preview notification email/ }).click()
      await cond.show('5.1')
      await cond.show('6.1')
      await cond.show('7.1')
      await sleep(1500)

      const posterMs = cond.shown.find((s) => s.id === '3.6')?.t_ms ?? cond.now() / 2
      await saveTake(cond, page, outDir, { mode: board.mode, banner, poster_ms: posterMs })
      for (const run of Object.values(cond.runs)) {
        if (existsSync(traceFile(run.id))) copyFileSync(traceFile(run.id), join(outDir, `trace-file-${run.task}.json`))
      }
    } finally {
      closeNotepad(notepad)
      stopEnv()
    }
  })
