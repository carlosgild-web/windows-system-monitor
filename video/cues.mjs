/**
 * After a take: shown rows -> cues.json (start/end per subtitle), and the checks that make the
 * video trustworthy (ported from hl-bead-studio/video):
 *   - strict mode (a dry take on the scripted model): every storyboard row was shown, once, in order;
 *     flexible mode (a real model): every row shown is a storyboard row or a generic one, and the
 *     rows that never matched are listed;
 *   - every payload on screen equals the captured event it names (events.json: the console's
 *     GET /api/status and the run traces of GET /api/ai/runs/{id});
 *   - no payload shows a local path.
 *
 *   node cues.mjs out/ollama            build cues.json and check
 *   node cues.mjs out/ollama --verify   check only
 */
import { isDeepStrictEqual } from 'node:util'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
// Checked on string values, not JSON text: there a newline after "directory:" reads "y:\n".
const PATH_RE = /(?<![A-Za-z])[A-Za-z]:\\[^\s\\]|\\Users\\|\/home\/|MyData|AppData/
export const hasLocalPath = (value) =>
  typeof value === 'string'
    ? PATH_RE.test(value)
    : value !== null && typeof value === 'object'
      ? Object.values(value).some(hasLocalPath)
      : false
const TAIL_MS = 1500 // the last subtitle stays this long after its hold

const readJson = (path) => JSON.parse(readFileSync(path, 'utf8'))

export function pick(value, path) {
  if (!path) return value
  for (const part of path.split('.')) value = value?.[/^\d+$/.test(part) ? Number(part) : part]
  return value
}

export function buildCues(shown) {
  return shown.map((s, i) => ({
    id: s.id,
    start_ms: s.t_ms,
    end_ms: i + 1 < shown.length ? shown[i + 1].t_ms : s.t_ms + s.hold_ms + TAIL_MS,
    subtitle: s.subtitle,
  }))
}

export function verify(storyboard, shown, events, mode) {
  const problems = []
  const notes = []
  const expected = storyboard.rows.map((r) => r.id)
  const got = shown.map((s) => s.id)
  if (mode === 'flexible') {
    const unknown = got.filter((id) => !expected.includes(id) && !/^g\d+$/.test(id))
    if (unknown.length) problems.push(`rows not in the storyboard: ${unknown.join(', ')}`)
    const missing = expected.filter((id) => !got.includes(id))
    if (missing.length) notes.push(`never matched (not in the video): ${missing.join(', ')}`)
    const generic = got.filter((id) => /^g\d+$/.test(id))
    if (generic.length) notes.push(`generic rows for unforeseen events: ${generic.length}`)
  } else {
    const wanted = expected.filter((id) => got.includes(id) || !storyboard.rows.find((r) => r.id === id)?.optional)
    if (!isDeepStrictEqual(got, wanted)) {
      const missing = wanted.filter((id) => !got.includes(id))
      problems.push(`rows: expected ${wanted.length} in storyboard order, got ${got.length}` + (missing.length ? `; missing ${missing.join(', ')}` : '; order differs'))
    }
  }
  let checked = 0
  for (const s of shown) {
    if (!s.source) continue
    const ev = events[s.source.index]
    if (!ev) {
      problems.push(`${s.id}: captured event #${s.source.index} is missing`)
      continue
    }
    checked++
    if (!isDeepStrictEqual(s.payload, pick(ev.data, s.source.pick))) problems.push(`${s.id}: the payload on screen differs from the capture`)
    if (hasLocalPath(s.payload)) problems.push(`${s.id}: the payload shows a local path`)
  }
  return { problems, checked, notes }
}

function main() {
  const [dirArg, flag] = process.argv.slice(2)
  if (!dirArg) {
    console.error('usage: node cues.mjs out/<take> [--verify]')
    process.exit(2)
  }
  const dir = resolve(HERE, dirArg)
  const take = existsSync(join(dir, 'take.json')) ? readJson(join(dir, 'take.json')) : {}
  const storyboard = readJson(join(HERE, take.storyboard ?? 'storyboard-ollama.json'))
  const mode = take.mode ?? 'flexible'
  const shown = readJson(join(dir, 'shown.json'))
  if (flag !== '--verify') {
    writeFileSync(join(dir, 'cues.json'), JSON.stringify(buildCues(shown), null, 2))
    console.log(`cues.json: ${shown.length} cues`)
  }
  const { problems, checked, notes } = verify(storyboard, shown, readJson(join(dir, 'events.json')), mode)
  for (const note of notes) console.log(`note: ${note}`)
  if (problems.length) {
    console.error(problems.map((p) => `FAIL ${p}`).join('\n'))
    process.exit(1)
  }
  const order = mode === 'flexible' ? 'shown (flexible mode)' : 'in storyboard order'
  console.log(`ok: ${shown.length} rows ${order}; ${checked} payloads equal the capture; no local paths`)
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main()
