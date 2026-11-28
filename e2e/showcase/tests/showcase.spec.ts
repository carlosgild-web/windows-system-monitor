import { spawnSync } from 'node:child_process'
import { mkdirSync, rmSync } from 'node:fs'
import { join } from 'node:path'

import { expect, type Page, test } from '@playwright/test'

import { INCIDENT, ROOT, TICKET } from '../env'

/**
 * The README's screenshots and GIF (docs/showcase/), on the real monitors and console started by
 * setup.ts with a scripted model: `npm run showcase` (screenshots), `npm run showcase:gif` (the GIF,
 * needs ffmpeg). The model's turns come from assistant-script.json; the tools' results, the number
 * check and the ticket fields are real.
 */
const OUT = join(ROOT, 'docs', 'showcase')
const SIZE = { width: 1280, height: 800 }
mkdirSync(OUT, { recursive: true })

/** The portfolio banner and its pill stay out of the README images. */
async function open(page: Page, path = '/') {
  await page.addInitScript(() => {
    try { localStorage.setItem('wsm-demo-guide', 'pill') } catch { /* not remembered */ }
  })
  await page.goto(path)
  await page.addStyleTag({ content: '.guide-pill { display: none !important; }' })
}

const shot = (page: Page, name: string) => page.screenshot({ path: join(OUT, `${name}.png`) })

const groceriesRow = (page: Page) => page.locator('#inc-list .row', { hasText: 'Groceries spend' })

async function explain(page: Page) {
  await groceriesRow(page).getByRole('button', { name: /Explain/ }).click()
  await expect(page.locator('#ai-body .ai-answer')).toBeVisible()
  await expect(page.locator('#ai-body')).toContainText('Every number in the answer comes from')
}

async function draftWithAI(page: Page) {
  await page.locator('#ai-draft').click()
  await expect(page.locator('#ai-bar .ai-tag')).toBeVisible()
  await expect(page.locator('#ai-bar')).toContainText('set by the rules, not the model')
}

test.use({ viewport: SIZE })

test('screenshots for the README', async ({ page, browser }) => {
  await open(page)
  await expect(groceriesRow(page)).toContainText('Critical')
  await page.waitForTimeout(800)
  await shot(page, 'console-incidents')

  await explain(page)
  await page.waitForTimeout(400)
  await shot(page, 'explain')
  await page.locator('#ai-body').evaluate((el) => (el.scrollTop = el.scrollHeight))
  await page.waitForTimeout(300)
  await shot(page, 'explain-steps')

  await page.emulateMedia({ colorScheme: 'dark' })
  await page.locator('#ai-body').evaluate((el) => (el.scrollTop = 0))
  await page.waitForTimeout(300)
  await shot(page, 'explain-dark')
  await page.emulateMedia({ colorScheme: 'light' })

  await open(page, `/tickets/${TICKET}`)
  await draftWithAI(page)
  await page.waitForTimeout(400)
  await shot(page, 'ticket-ai-draft')

  const phone = await browser.newPage({ viewport: { width: 390, height: 844 } })
  await open(phone)
  await expect(groceriesRow(phone)).toBeVisible()
  await phone.locator('#card-incidents').evaluate((el) => window.scrollTo(0, el.getBoundingClientRect().top + window.scrollY - 70))
  await phone.waitForTimeout(500)
  await shot(phone, 'phone-incidents')
  await phone.close()
})

/** WebM -> GIF with the portfolio's README spec: 10 fps, 960 px wide, its own 96-colour palette. */
function toGif(webm: string, gif: string, startS: number, endS: number) {
  const filters =
    'fps=10,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=96:stats_mode=diff[p];' +
    '[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle'
  const run = spawnSync(
    'ffmpeg',
    ['-y', '-loglevel', 'error', '-ss', startS.toFixed(2), '-to', endS.toFixed(2), '-i', webm, '-vf', filters, '-loop', '0', gif],
    { timeout: 180_000, encoding: 'utf8' },
  )
  if (run.error || run.status !== 0) {
    console.warn(`showcase: no GIF (${run.error?.message ?? run.stderr.trim()}); the WebM stays at ${webm}`)
    return false
  }
  return true
}

/**
 * The README GIF: an open critical incident -> Explain (the agent's steps, the answer, the checked
 * numbers) -> the incident's ticket -> Draft with AI (the text changes, the priority does not).
 */
test('recorded demo for the README GIF @gif', async ({ browser }) => {
  const context = await browser.newContext({
    baseURL: 'http://localhost:5758', viewport: SIZE, recordVideo: { dir: join(OUT, '.gif-video'), size: SIZE },
  })
  const page = await context.newPage()
  const t0 = Date.now()
  await open(page)
  await expect(groceriesRow(page)).toContainText('Critical')
  await page.waitForTimeout(1200)
  const startS = (Date.now() - t0) / 1000 - 0.2

  // The open incidents; the critical one is the budget.
  await groceriesRow(page).hover()
  await page.waitForTimeout(1800)
  await groceriesRow(page).getByRole('button', { name: /Explain/ }).hover()
  await page.waitForTimeout(500)
  await groceriesRow(page).getByRole('button', { name: /Explain/ }).click()

  // The agent's steps as they happen, then the answer and the checked numbers.
  await expect(page.locator('#ai-body .ai-answer')).toBeVisible()
  await page.waitForTimeout(3500)
  const body = page.locator('#ai-body')
  for (let y = 0; y <= 6; y++) {
    await body.evaluate((el, f) => (el.scrollTop = (el.scrollHeight - el.clientHeight) * f), y / 6)
    await page.waitForTimeout(260)
  }
  await page.waitForTimeout(2800)
  await page.keyboard.press('Escape')
  await page.waitForTimeout(500)

  // The incident's ticket: Draft with AI writes the text; the priority stays the rules'.
  await open(page, `/tickets/${TICKET}`)
  await page.waitForTimeout(1800)
  await page.locator('#ai-draft').hover()
  await page.waitForTimeout(500)
  await draftWithAI(page)
  await page.waitForTimeout(3500)
  await page.locator('#t-work-sec').scrollIntoViewIfNeeded()
  await page.waitForTimeout(2800)
  const endS = (Date.now() - t0) / 1000

  const video = page.video()!
  await context.close()
  const webm = join(OUT, 'demo.webm')
  await video.saveAs(webm)
  rmSync(join(OUT, '.gif-video'), { recursive: true, force: true })
  console.log(`showcase: GIF from ${startS.toFixed(1)} s to ${endS.toFixed(1)} s (${(endS - startS).toFixed(1)} s)`)
  if (toGif(webm, join(OUT, 'demo.gif'), Math.max(0, startS), endS)) rmSync(webm)
  expect(INCIDENT).toContain('Groceries')
})
