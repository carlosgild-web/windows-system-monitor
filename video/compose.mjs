/**
 * take.webm (+ desktop clips) -> video.mp4 (H.264) and subtitles.en.srt. Ported from
 * hl-bead-studio/video (the portfolio's reference), unchanged apart from the colours and the
 * clip spec's file name.
 *
 *   node compose.mjs out/demo-dry --cut-gaps
 *   node compose.mjs out/groq --cut-gaps --readme
 *
 * The video is a list of pieces, encoded apart and joined without re-encoding:
 * - take pieces;
 * - each desktop clip named in cues-desktop.json (<clip>.mp4 + <clip>.json), in place of
 *   the browser frames recorded while it ran. It is scaled into the stage's 1920x960 area,
 *   with a "screen recording" label and its subtitles in the stage's subtitle bar; with a
 *   `zoom` in its spec, it then cuts to a crop of the same frames (labelled "zoomed in");
 * - with --cut-gaps, every wait over 3 s is kept for 1 s with a label that says how long it
 *   really was: inside a chat turn, where nothing changed on screen (the model), and the
 *   waits the take wrote to waits.json (a generation, the end of a render). A wait is never
 *   removed without that label.
 *
 * --readme also writes video-readme.mp4 (1280x720, two-pass, under 10 MB for GitHub's
 * inline player) and poster.png (at take.json's poster_ms). The subtitles are burned into
 * the stage already; the .srt is for players and search.
 */
import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const W = 1920
const STAGE_H = 960
const H = 1080
const GAP_S = Number(process.env.VIDEO_GAP_S ?? 3) // a wait longer than this is shortened
const KEEP_S = 1 // to this, with its label
const README_MB = 9.5 // GitHub plays inline up to 10 MB on free accounts
const BG = '0x0f1420' // the stage's colours (stage.html)
const BAR = '0x0a0e17'
const AMBER = '0x8aa3ff' // the stage's accent (the name is kept from the port)
// drawtext needs a font file; Segoe UI is the stage's font on Windows.
const FONT = (process.env.VIDEO_FONT || 'C:/Windows/Fonts/segoeui.ttf').replace(/:/g, '\\:')

function stamp(ms) {
  const t = Math.max(0, Math.round(ms))
  const pad = (n, w = 2) => String(n).padStart(w, '0')
  return `${pad(Math.floor(t / 3_600_000))}:${pad(Math.floor(t / 60_000) % 60)}:${pad(Math.floor(t / 1000) % 60)},${pad(t % 1000, 3)}`
}

export function srt(cues) {
  return cues.map((c, i) => `${i + 1}\n${stamp(c.start_ms)} --> ${stamp(c.end_ms)}\n${c.subtitle}\n`).join('\n')
}

function duration(file) {
  const out = execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', file], { encoding: 'utf8' })
  return Number(out.trim())
}

/**
 * The model waits to shorten, in seconds of the take: inside each chat turn (from the request
 * to `done`), the spans where no row was on screen and no event changed the app for over
 * GAP_S, seen in the app as "The assistant is working…".
 */
export function findGaps(events, shown) {
  const busy = [
    ...shown.map((s) => [s.t_ms, s.t_ms + s.hold_ms]),
    ...events.map((e) => [e.t_ms, e.t_ms + 800]), // the app renders what came
  ].sort((a, b) => a[0] - b[0])
  const gaps = []
  for (const req of events.filter((e) => e.type === 'request')) {
    const done = events.find((e) => e.type === 'done' && e.t_ms > req.t_ms)
    if (!done) continue
    let at = req.t_ms
    for (const [from, to] of busy) {
      if (to <= at || from >= done.t_ms) continue
      if (from - at > GAP_S * 1000) gaps.push({ from: at / 1000, to: from / 1000, what: 'waiting for the model' })
      at = Math.max(at, to)
    }
  }
  return gaps
}

/** The waits the take wrote (`{ from_ms, to_ms, what }`), over GAP_S, as gaps. */
export function takeWaits(waits) {
  return waits
    .filter((w) => w.to_ms - w.from_ms > GAP_S * 1000)
    .map((w) => ({ from: w.from_ms / 1000, to: w.to_ms / 1000, what: w.what }))
}

/**
 * The pieces of the final video, in order. Take pieces are [from, to) of the take; each
 * desktop clip (`{ clip, start_ms, end_ms }`, from its .json) replaces the take's frames
 * recorded while it ran. A wait that overlaps an earlier cut is dropped.
 */
export function planPieces(takeS, gaps, clips = []) {
  const cuts = [...gaps.map((g) => ({ kind: 'gap', ...g }))]
  for (const c of clips) cuts.push({ kind: 'clip', clip: c.clip, from: c.start_ms / 1000, to: c.end_ms / 1000 })
  cuts.sort((a, b) => a.from - b.from)
  const pieces = []
  let pos = 0
  for (const cut of cuts) {
    if (cut.from < pos) continue // overlaps an earlier cut
    if (cut.from > pos) pieces.push({ src: 'take', from: pos, to: cut.from })
    if (cut.kind === 'gap') {
      const waited = cut.to - cut.from
      const what = cut.what ?? 'waiting for the model'
      pieces.push({ src: 'take', from: cut.from, to: cut.from + KEEP_S, label: `${what}: ${waited.toFixed(0)} s, shortened to ${KEEP_S} s` })
    } else {
      pieces.push({ src: 'clip', clip: cut.clip, from: cut.from, to: cut.to })
    }
    pos = cut.to
  }
  if (pos < takeS) pieces.push({ src: 'take', from: pos, to: takeS })
  return pieces
}

/** A take time (ms) in the final video, given each piece's length there (s). */
export function mapper(pieces, lengths) {
  return (ms) => {
    const t = ms / 1000
    let out = 0
    for (const [i, p] of pieces.entries()) {
      if (t < p.from) return out * 1000
      if (p.src === 'take' && t < p.to) return (out + Math.min(t - p.from, lengths[i])) * 1000
      if (p.src === 'clip' && t < p.to) return out * 1000
      out += lengths[i]
    }
    return out * 1000
  }
}

/** The zoom's rectangle in the capture: `factor` times narrower than the area, around
 * (cx, cy), inside the frame, in the stage's 2:1 aspect ratio. */
export function zoomRect(area, zoom) {
  const w = Math.round(area.width / zoom.factor / 2) * 2
  const h = Math.round(w / 4) * 2
  const clamp = (v, max) => Math.max(0, Math.min(max, Math.round(v)))
  return {
    w,
    h,
    x: clamp(zoom.cx * area.width - w / 2, area.width - w),
    y: clamp(zoom.cy * area.height - h / 2, area.height - h),
  }
}

function drawText(file, size, color, xy, enable) {
  return `drawtext=fontfile='${FONT}':textfile='${file}':fontsize=${size}:fontcolor=${color}:${xy}${enable ? `:enable='${enable}'` : ''}`
}

/**
 * The filter for one piece of a desktop clip that starts `from` seconds into it: optionally
 * a crop (the zoom), scaled into the stage's 1920x960 area, the "screen recording" label,
 * and the subtitles of that time in the stage's subtitle bar.
 * (Not zoompan: on video input it multiplies the frames.)
 */
function clipFilter(spec, textFiles, { from, crop }) {
  const parts = [
    ...(crop ? [`crop=${crop.w}:${crop.h}:${crop.x}:${crop.y}`] : []),
    `scale=${W}:${STAGE_H}:force_original_aspect_ratio=decrease:flags=lanczos`,
    `pad=${W}:${STAGE_H}:(ow-iw)/2:(oh-ih)/2:color=${BG}`,
    `pad=${W}:${H}:0:0:color=${BAR}`,
    drawText(textFiles.label, 22, 'white@0.9', `x=w-text_w-24:y=${STAGE_H}-text_h-${crop ? 96 : 50}:box=1:boxcolor=${BG}@0.75:boxborderw=10`),
    ...(crop ? [drawText(textFiles.zoom, 22, AMBER, `x=w-text_w-24:y=${STAGE_H}-text_h-50:box=1:boxcolor=${BG}@0.75:boxborderw=10`)] : []),
    // drawtext's t is the piece's own time
    ...spec.cues.map((c, i) =>
      drawText(textFiles.cues[i], 30, 'white', `x=(w-text_w)/2:y=${STAGE_H}+(${H - STAGE_H}-text_h)/2`, `between(t+${from},${c.start},${c.end})`),
    ),
    'fps=30', 'format=yuv420p', 'setsar=1',
  ]
  return parts.join(',')
}

function encodeArgs(out) {
  return ['-c:v', 'libx264', '-preset', 'medium', '-crf', '20', '-pix_fmt', 'yuv420p', '-r', '30', '-movflags', '+faststart', '-an', out]
}

/** The README copy: 1280x720, two-pass to stay under README_MB, and a poster frame. */
function readmeCopy(dir, ffmpeg, posterAt) {
  const seconds = duration(join(dir, 'video.mp4'))
  const kbps = Math.floor((README_MB * 8 * 1024) / seconds) - 16
  const common = ['-i', 'video.mp4', '-vf', 'scale=1280:720:flags=lanczos', '-c:v', 'libx264', '-preset', 'slow', '-b:v', `${kbps}k`, '-pix_fmt', 'yuv420p', '-an']
  const nul = process.platform === 'win32' ? 'NUL' : '/dev/null'
  ffmpeg([...common, '-pass', '1', '-passlogfile', 'readme-pass', '-f', 'mp4', nul])
  ffmpeg([...common, '-pass', '2', '-passlogfile', 'readme-pass', '-movflags', '+faststart', 'video-readme.mp4'])
  ffmpeg(['-ss', String(posterAt), '-i', 'video.mp4', '-frames:v', '1', '-update', '1', '-vf', 'scale=1280:720:flags=lanczos', 'poster.png'])
  const mb = statSync(join(dir, 'video-readme.mp4')).size / 1024 / 1024
  if (mb > 10) throw new Error(`video-readme.mp4 is ${mb.toFixed(1)} MB, over GitHub's 10 MB`)
  return mb
}

function main() {
  const [dirArg, ...flags] = process.argv.slice(2)
  if (!dirArg) {
    console.error('usage: node compose.mjs out/<video> [--cut-gaps] [--readme]')
    process.exit(2)
  }
  const dir = resolve(HERE, dirArg)
  if (!existsSync(join(dir, 'take.webm'))) {
    console.error(`${join(dir, 'take.webm')} not found: record the take first`)
    process.exit(1)
  }
  const read = (name, fallback) => (existsSync(join(dir, name)) ? JSON.parse(readFileSync(join(dir, name), 'utf8')) : fallback)
  const ffmpeg = (args) => execFileSync('ffmpeg', ['-y', '-loglevel', 'error', ...args], { cwd: dir, stdio: 'inherit' })
  const cues = read('cues.json')
  const take = read('take.json', {})
  const clipSpec = JSON.parse(readFileSync(join(HERE, 'cues-desktop.json'), 'utf8'))
  const clips = Object.keys(clipSpec.clips)
    .filter((clip) => existsSync(join(dir, `${clip}.json`)) && existsSync(join(dir, `${clip}.mp4`)))
    .map((clip) => ({ ...read(`${clip}.json`), clip }))
  const gaps = flags.includes('--cut-gaps') ? [...findGaps(read('events.json'), read('shown.json')), ...takeWaits(read('waits.json', []))] : []
  const pieces = planPieces(duration(join(dir, 'take.webm')), gaps, clips)

  // Per clip: its spec, and plain-text files for drawtext (no escaping of ':' or ',').
  const specs = {}
  for (const clip of clips) {
    const spec = clipSpec.clips[clip.clip]
    const textFiles = { label: `${clip.clip}-label.txt`, zoom: `${clip.clip}-zoom.txt`, cues: spec.cues.map((_, i) => `${clip.clip}-cue-${i}.txt`) }
    writeFileSync(join(dir, textFiles.label), clipSpec.label)
    if (spec.zoom) writeFileSync(join(dir, textFiles.zoom), spec.zoom.label)
    spec.cues.forEach((c, i) => writeFileSync(join(dir, textFiles.cues[i]), c.subtitle))
    specs[clip.clip] = { spec, textFiles, clip }
  }

  const files = []
  const lengths = []
  const next = () => `part-${String(files.length + 1).padStart(2, '0')}.mp4`
  for (const [i, p] of pieces.entries()) {
    if (p.src === 'take') {
      const file = next()
      let vf = 'fps=30,format=yuv420p,setsar=1'
      if (p.label) {
        writeFileSync(join(dir, `gap-${i}.txt`), p.label)
        vf += `,${drawText(`gap-${i}.txt`, 26, AMBER, `x=(w-text_w)/2:y=24:box=1:boxcolor=${BG}@0.85:boxborderw=12`)}`
      }
      ffmpeg(['-ss', String(p.from), '-i', 'take.webm', '-t', String(p.to - p.from), '-vf', vf, ...encodeArgs(file)])
      files.push(file)
      lengths.push(duration(join(dir, file)))
    } else {
      const { spec, textFiles, clip } = specs[p.clip]
      const source = `${clip.clip}.mp4`
      if (!spec.zoom) {
        const file = next()
        ffmpeg(['-i', source, '-vf', clipFilter(spec, textFiles, { from: 0 }), ...encodeArgs(file)])
        files.push(file)
        lengths.push(duration(join(dir, file)))
        continue
      }
      // The whole window, then a cut to the zoomed crop of the same frames.
      const zoomAt = spec.zoom.start
      const whole = next()
      ffmpeg(['-i', source, '-t', String(zoomAt), '-vf', clipFilter(spec, textFiles, { from: 0 }), ...encodeArgs(whole)])
      files.push(whole)
      const zoomed = next()
      const crop = zoomRect(clip.area, spec.zoom)
      ffmpeg(['-ss', String(zoomAt), '-i', source, '-vf', clipFilter(spec, textFiles, { from: zoomAt, crop }), ...encodeArgs(zoomed)])
      files.push(zoomed)
      lengths.push(duration(join(dir, whole)) + duration(join(dir, zoomed)))
    }
  }
  writeFileSync(join(dir, 'parts.txt'), files.map((f) => `file '${f}'`).join('\n'))
  ffmpeg(['-f', 'concat', '-safe', '0', '-i', 'parts.txt', '-c', 'copy', '-movflags', '+faststart', 'video.mp4'])

  // Subtitles on the final clock: the take's cues mapped, each clip's cues where it is.
  const map = mapper(pieces, lengths)
  // A take cue ends where a desktop clip starts: the clip has its own subtitles.
  const clipStarts = pieces.map((p, k) => (p.src === 'clip' ? lengths.slice(0, k).reduce((a, b) => a + b, 0) * 1000 : null)).filter((v) => v !== null)
  const final = cues
    .map((c) => ({ ...c, start_ms: map(c.start_ms), end_ms: map(c.end_ms) }))
    .map((c) => ({ ...c, end_ms: Math.min(c.end_ms, ...clipStarts.filter((s) => s > c.start_ms)) }))
    .filter((c) => c.end_ms - c.start_ms > 300)
  for (const [k, p] of pieces.entries()) {
    if (p.src !== 'clip') continue
    const at = lengths.slice(0, k).reduce((a, b) => a + b, 0) * 1000
    const { spec } = specs[p.clip]
    final.push(...spec.cues.map((c) => ({ id: c.id, start_ms: at + c.start * 1000, end_ms: at + Math.min(c.end * 1000, lengths[k] * 1000), subtitle: c.subtitle })))
  }
  final.sort((a, b) => a.start_ms - b.start_ms)
  writeFileSync(join(dir, 'subtitles.en.srt'), srt(final))
  writeFileSync(join(dir, 'pieces.json'), JSON.stringify(pieces.map((p, i) => ({ ...p, seconds: lengths[i] })), null, 2))

  const total = duration(join(dir, 'video.mp4'))
  console.log(`${join(dir, 'video.mp4')} (${total.toFixed(1)} s; ${gaps.length} waits shortened)\n${join(dir, 'subtitles.en.srt')} (${final.length} cues)`)
  if (flags.includes('--readme')) {
    const posterAt = take.poster_ms != null ? map(take.poster_ms) / 1000 : total / 2
    const mb = readmeCopy(dir, ffmpeg, posterAt)
    console.log(`${join(dir, 'video-readme.mp4')} (${mb.toFixed(1)} MB)\n${join(dir, 'poster.png')}`)
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main()
