/**
 * Desktop capture of another program's window (decision 0027; generalizes hl-create-design's
 * kicad.mjs). Playwright cannot see a desktop window, so this module waits for it, maximizes
 * it, and records its screen with ffmpeg `gdigrab`. compose.mjs puts the clip in the take
 * where it was recorded.
 *
 * Windows only. PowerShell and ffmpeg, no extra dependency. The recorded area is the window's
 * monitor working area (no taskbar) minus the window's title bar (masked: it could show a
 * file name). The title is still checked for a local path when the window is found.
 */
import { execFile, execFileSync } from 'node:child_process'
import { writeFileSync } from 'node:fs'
import { join } from 'node:path'

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// Checked on the window title: a drive letter, a home folder or this machine's data folder.
export const PATH_RE = /(?<![A-Za-z])[A-Za-z]:\\[^\s\\]|\\Users\\|\/home\/|MyData/

function powershell(script) {
  return execFileSync('powershell', ['-NoProfile', '-NonInteractive', '-Command', script], {
    encoding: 'utf8',
  }).trim()
}

// Physical pixels (the process is made DPI-aware before asking), so they match gdigrab.
const WIN32 = String.raw`
Add-Type @"
using System; using System.Runtime.InteropServices;
public class VideoWin {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
}
"@
[VideoWin]::SetProcessDPIAware() | Out-Null
Add-Type -AssemblyName System.Windows.Forms
`

/**
 * The window of process `pid` once its title matches `ready` (a RegExp): a program shows its
 * own name first and the document's once it has loaded it.
 */
export async function waitForWindow(pid, { ready = /./, name = 'the window', timeoutMs = 90_000 } = {}) {
  const deadline = Date.now() + timeoutMs
  let title = ''
  while (Date.now() < deadline) {
    title = powershell(`(Get-Process -Id ${Number(pid)} -ErrorAction SilentlyContinue).MainWindowTitle`)
    if (title && ready.test(title)) return { pid, title }
    await sleep(400)
  }
  throw new Error(`${name} did not show its document within ${timeoutMs / 1000} s (title "${title}")`)
}

/** Maximize the window, bring it to the front, and return the area to record. */
export function maximize(pid) {
  const out = powershell(`${WIN32}
$h = (Get-Process -Id ${Number(pid)}).MainWindowHandle
[VideoWin]::ShowWindow($h, 3) | Out-Null
[VideoWin]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 700
$a = [System.Windows.Forms.Screen]::FromHandle($h).WorkingArea
# SM_CYCAPTION (4) + SM_CYSIZEFRAME (33) + SM_CXPADDEDBORDER (92): a maximized title bar
$c = [VideoWin]::GetSystemMetrics(4) + [VideoWin]::GetSystemMetrics(33) + [VideoWin]::GetSystemMetrics(92)
"$($a.X)|$($a.Y)|$($a.Width)|$($a.Height)|$c"`)
  const [x, y, width, height, caption] = out.split('|').map(Number)
  return titleBarMasked({ x, y, width, height }, caption)
}

/** The working area without the title bar, in even sizes (H.264 needs them). */
export function titleBarMasked(area, caption) {
  const top = Math.max(0, caption)
  const height = area.height - top
  return { x: area.x, y: area.y + top, width: area.width - (area.width % 2), height: height - (height % 2) }
}

/** Record `area` of the desktop for `seconds` into `file` (H.264, no mouse pointer). */
export function record(area, seconds, file) {
  return new Promise((resolve, reject) => {
    execFile(
      'ffmpeg',
      [
        '-y', '-loglevel', 'error',
        '-f', 'gdigrab', '-framerate', '30', '-draw_mouse', '0',
        '-offset_x', String(area.x), '-offset_y', String(area.y),
        '-video_size', `${area.width}x${area.height}`, '-i', 'desktop',
        '-t', String(seconds), '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '16',
        '-pix_fmt', 'yuv420p', file,
      ],
      { timeout: (seconds + 30) * 1000 },
      (err) => (err ? reject(err) : resolve()),
    )
  })
}

/**
 * One clip: wait for the window, maximize it, let it redraw, record it. Writes `<clip>.mp4`
 * and `<clip>.json`: when it started and ended on the take's clock, the title, the area.
 */
export async function captureWindow({ pid, clip, outDir, now, seconds, ready, name, settleMs = 1500 }) {
  const window = await waitForWindow(pid, { ready, name })
  if (PATH_RE.test(window.title)) throw new Error(`${name}'s title shows a path: ${window.title}`)
  const area = maximize(pid)
  await sleep(settleMs) // the program redraws for the new size
  const start_ms = now()
  await record(area, seconds, join(outDir, `${clip}.mp4`))
  const end_ms = now()
  const info = { clip, start_ms, end_ms, seconds, title: window.title, area }
  writeFileSync(join(outDir, `${clip}.json`), JSON.stringify(info, null, 2))
  return info
}
