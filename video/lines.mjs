/**
 * file:symbol -> the current line and a short excerpt, found by regex in the working tree.
 * No line numbers are written anywhere by hand: the stage asks this module at take time,
 * and `--check` fails when a symbol the storyboard names is gone (decision 0028).
 *
 *   node lines.mjs --check storyboard.json
 *   node lines.mjs MonitoringConsole/ai/agent.py AssistantRun._loop
 *   node lines.mjs scripts/lib/MonitorActions.ps1 Invoke-ThresholdAlerts
 *   node lines.mjs monitoring_settings.json processes.notepad.exe
 *
 * Ported from hl-bead-studio/video; adds PowerShell functions and JSON keys (a list item is
 * found by its "name" or "display_name").
 */
import { readFileSync } from 'node:fs'
import { dirname, join, resolve as resolvePath } from 'node:path'
import { fileURLToPath } from 'node:url'

export const ROOT = resolvePath(dirname(fileURLToPath(import.meta.url)), '..')
const EXCERPT_LINES = 9

const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

/** Lines that define `name` in a Python, PowerShell, JSON, TypeScript/JS/HTML or Markdown file. */
function definitionPatterns(name, file) {
  const n = escape(name)
  if (/\.ps(m?)1$/.test(file)) return [new RegExp(`^(\\s*)function\\s+${n}\\b`, 'i')]
  if (file.endsWith('.json')) {
    return [new RegExp(`^(\\s*)"${n}"\\s*:`), new RegExp(`^(\\s*)"(?:name|display_name)"\\s*:\\s*"${n}"`)]
  }
  if (file.endsWith('.py')) {
    return [
      new RegExp(`^(\\s*)(?:async\\s+)?def ${n}\\b`),
      new RegExp(`^(\\s*)class ${n}\\b`),
      new RegExp(`^(\\s*)${n}\\s*(?::[^=]+)?=`),
    ]
  }
  if (file.endsWith('.md')) return [new RegExp(`^()#+ .*${n}`)]
  return [
    new RegExp(`^(\\s*)(?:export\\s+)?(?:default\\s+)?(?:async\\s+)?function\\*?\\s*${n}\\b`),
    new RegExp(`^(\\s*)(?:export\\s+)?(?:const|let|type|interface|class)\\s+${n}\\b`),
  ]
}

function findFrom(lines, start, name, file, minIndent) {
  const patterns = definitionPatterns(name, file)
  for (let i = start; i < lines.length; i++) {
    for (const re of patterns) {
      const m = re.exec(lines[i])
      if (m && m[1].length >= minIndent) return { index: i, indent: m[1].length }
    }
  }
  return null
}

function excerpt(lines, index, indent, file) {
  if (file.endsWith('.md')) {
    // a heading and its section, up to the next heading
    const end = lines.findIndex((l, i) => i > index && /^#+ /.test(l))
    return lines
      .slice(index, end === -1 ? undefined : end)
      .filter((l) => l.trim())
      .slice(0, EXCERPT_LINES)
      .join('\n')
  }
  const out = [lines[index]]
  for (let i = index + 1; i < lines.length && out.length < EXCERPT_LINES; i++) {
    const line = lines[i]
    const dedent = line.trim() !== '' && line.length - line.trimStart().length <= indent
    if (dedent && !/^\s*[)\]}]/.test(line)) break
    out.push(line)
  }
  while (out.length && out[out.length - 1].trim() === '') out.pop()
  const cut = Math.min(...out.filter((l) => l.trim()).map((l) => l.length - l.trimStart().length))
  return out.map((l) => l.slice(cut)).join('\n')
}

/** `symbol` may be dotted: "AssistantRun._loop" looks for `_loop` inside `AssistantRun`.
 * In JSON a part may be a list item's name, and names with dots ("notepad.exe") are kept whole
 * when the dotted split does not resolve. */
export function resolve(file, symbol) {
  if (file.endsWith('.json')) return resolveJson(file, symbol)
  const text = readFileSync(join(ROOT, file), 'utf8')
  const lines = text.replace(/\r\n/g, '\n').split('\n')
  let at = { index: 0, indent: -1 }
  for (const part of symbol.split('.')) {
    const found = findFrom(lines, at.index, part, file, at.indent + 1)
    if (!found) throw new Error(`${file}: symbol "${symbol}" not found (part "${part}")`)
    at = found
  }
  return { file, symbol, line: at.index + 1, excerpt: excerpt(lines, at.index, at.indent, file) }
}

/** JSON: each part is a key, or a list item's "name"/"display_name"; the excerpt is the object
 * or member the last part opens (an item found by name shows its whole object). */
function resolveJson(file, symbol) {
  const text = readFileSync(join(ROOT, file), 'utf8')
  const lines = text.replace(/\r\n/g, '\n').split('\n')
  const parts = []
  for (const piece of symbol.split('.')) {
    // "notepad.exe": a part that ends in a known extension joins the previous one
    if (parts.length && /^(exe|csv|log|ps1|json)$/.test(piece)) parts[parts.length - 1] += `.${piece}`
    else parts.push(piece)
  }
  let at = { index: 0, indent: -1 }
  for (const part of parts) {
    const found = findFrom(lines, at.index, part, file, at.indent + 1)
    if (!found) throw new Error(`${file}: key "${symbol}" not found (part "${part}")`)
    at = found
  }
  let index = at.index
  let indent = at.indent
  if (/^\s*"(?:name|display_name)"\s*:/.test(lines[index])) {
    // a list item found by its name: show the item from its opening brace
    while (index > 0 && !/^\s*\{\s*$/.test(lines[index - 1])) index--
    index = Math.max(0, index - 1)
    indent = lines[index].length - lines[index].trimStart().length
  }
  const out = [lines[index]]
  for (let i = index + 1; i < lines.length && out.length < EXCERPT_LINES + 3; i++) {
    out.push(lines[i])
    if (lines[i].length - lines[i].trimStart().length <= indent && /^\s*[}\]]/.test(lines[i])) break
  }
  const cut = Math.min(...out.filter((l) => l.trim()).map((l) => l.length - l.trimStart().length))
  return { file, symbol, line: index + 1, excerpt: out.map((l) => l.slice(cut)).join('\n') }
}

/** Every [file, symbol] the storyboard's rows name. */
export function callouts(storyboard) {
  return storyboard.rows.flatMap((row) => (row.callouts ?? []).map(([file, symbol]) => ({ row: row.id, file, symbol })))
}

function check(path) {
  const storyboard = JSON.parse(readFileSync(path, 'utf8'))
  let failed = 0
  for (const { row, file, symbol } of callouts(storyboard)) {
    try {
      const r = resolve(file, symbol)
      console.log(`ok   ${row.padEnd(5)} ${file}:${r.line}  ${symbol}`)
    } catch (err) {
      failed++
      console.log(`FAIL ${row.padEnd(5)} ${err.message}`)
    }
  }
  console.log(failed ? `\n${failed} callout(s) not found` : '\nevery callout resolves')
  process.exit(failed ? 1 : 0)
}

if (process.argv[1] && resolvePath(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [flag, a, b] = process.argv.slice(2)
  if (flag === '--check') check(a)
  else {
    const r = resolve(flag, a ?? b)
    console.log(`${r.file}:${r.line}\n${r.excerpt}`)
  }
}
