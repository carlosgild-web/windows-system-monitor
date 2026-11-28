import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

import { COPY, INCIDENT, ROOT, SCRIPT, TICKET, powershell } from './env'

/**
 * Starts the real monitors from a clean scratch copy, with the scripted model, then makes the
 * groceries budget critical the way docs/test-environment.md says (the last Groceries amount,
 * 22.00 -> 90.00, in the COPY's CSV), and waits for the open incident and its ticket.
 * COMPUTERNAME is set for the copy, so no real computer name reaches the images.
 */
async function portsFree(timeoutMs: number) {
  // A previous run's teardown may still be stopping its console; video mode refuses busy ports.
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const busy = await Promise.all([5757, 5758].map((p) => fetch(`http://localhost:${p}/`).then(() => true, () => false)))
    if (!busy.some(Boolean)) return
    await new Promise((r) => setTimeout(r, 1000))
  }
}

export default async function setup() {
  await portsFree(20_000)
  const run = powershell(join(ROOT, 'scripts', 'video_mode.ps1'), {
    WSM_AI_SCRIPT: SCRIPT,
    NO_BROWSER: '1',
    COMPUTERNAME: 'WSM-DEMO',
  })
  if (run.status !== 0) throw new Error(`video mode did not start:\n${run.stdout}\n${run.stderr}`)

  const csv = join(COPY, 'sample_data', 'monthly_budget_sample.csv')
  const text = readFileSync(csv, 'utf8')
  const edited = text.replace('Groceries,Fruit and vegetables,22.00', 'Groceries,Fruit and vegetables,90.00')
  if (edited === text) throw new Error('the Groceries row to edit was not found in the copy')
  writeFileSync(csv, edited, 'utf8')

  const ticket = join(COPY, 'logs', 'tickets', `${TICKET}.html`)
  const deadline = Date.now() + 120_000
  while (Date.now() < deadline) {
    try {
      const status = await (await fetch('http://localhost:5758/api/status')).json()
      const open = (status.incidents ?? []).some((i: { id: string }) => i.id === INCIDENT)
      if (open && existsSync(ticket)) return
    } catch {
      // the console is still starting
    }
    await new Promise((r) => setTimeout(r, 2000))
  }
  throw new Error(`no ${INCIDENT} incident and ${TICKET} ticket after 120 s`)
}
