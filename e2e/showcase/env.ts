import { spawnSync } from 'node:child_process'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'

export const ROOT = resolve(__dirname, '..', '..')
/** The scratch copy video mode makes (scripts/video_mode.ps1). */
export const COPY = join(process.env.TEMP ?? tmpdir(), 'wsm-video')
export const SCRIPT = resolve(__dirname, 'assistant-script.json')
export const INCIDENT = 'document:Groceries spend (monthly budget):critical'
export const TICKET = 'INC0010001'

/** Windows PowerShell 5.1, the monitors' runtime. */
export function powershell(file: string, env: Record<string, string> = {}) {
  return spawnSync('powershell.exe', ['-ExecutionPolicy', 'Bypass', '-NoProfile', '-NonInteractive', '-File', file], {
    env: { ...process.env, ...env },
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    timeout: 180_000,
  })
}
