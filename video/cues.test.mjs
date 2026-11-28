/** `node --test` (npm run video:test): the honesty checks of cues.mjs. */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { buildCues, hasLocalPath, verify } from './cues.mjs'

const board = { rows: [{ id: '1.1' }, { id: '2.2' }, { id: '3.2', optional: true }] }
const events = [{ type: 'incident', data: { id: 'process:notepad.exe:warning', level: 'warning' } }]

test('a payload must equal the captured event it names', () => {
  const ok = [{ id: '1.1', t_ms: 0, hold_ms: 1000 }, { id: '2.2', t_ms: 1000, hold_ms: 1000,
    payload: { id: 'process:notepad.exe:warning', level: 'warning' }, source: { index: 0 } }]
  assert.deepEqual(verify(board, ok, events, 'strict').problems, [])
  const edited = [ok[0], { ...ok[1], payload: { id: 'process:notepad.exe:warning', level: 'critical' } }]
  assert.match(verify(board, edited, events, 'strict').problems[0], /differs from the capture/)
})

test('strict mode wants every required row, once, in order; optional rows may be absent', () => {
  const shown = [{ id: '2.2', t_ms: 0, hold_ms: 1 }, { id: '1.1', t_ms: 1, hold_ms: 1 }]
  assert.match(verify(board, shown, events, 'strict').problems[0], /order differs/)
  assert.deepEqual(verify(board, [{ id: '1.1' }, { id: '2.2' }], events, 'strict').problems, [])
})

test('flexible mode lists the rows that never matched and rejects unknown ones', () => {
  const r = verify(board, [{ id: '1.1' }, { id: 'g1' }, { id: '9.9' }], events, 'flexible')
  assert.match(r.problems[0], /9\.9/)
  assert.match(r.notes[0], /2\.2/)
})

test('a local path in a payload fails the take', () => {
  assert.ok(hasLocalPath({ a: ['C:\\Users\\someone\\x'] }))
  assert.ok(hasLocalPath('see AppData\\Local'))
  assert.ok(!hasLocalPath({ drive: 'C:\\', note: 'Disk C: is full' }))
})

test('a cue ends where the next one starts', () => {
  const cues = buildCues([{ id: 'a', t_ms: 0, hold_ms: 900, subtitle: 'x' }, { id: 'b', t_ms: 2000, hold_ms: 900, subtitle: 'y' }])
  assert.deepEqual(cues.map((c) => [c.start_ms, c.end_ms]), [[0, 2000], [2000, 4400]])
})
