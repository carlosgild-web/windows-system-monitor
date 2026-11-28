/** `node --test` (npm run video:test): how compose.mjs cuts a take (ported from hl-bead-studio). */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { findGaps, mapper, planPieces, srt, takeWaits, zoomRect } from './compose.mjs'

const desktop = { clip: 'popup', start_ms: 100_000, end_ms: 116_000 }

test('a desktop clip replaces the take where it was recorded', () => {
  assert.deepEqual(planPieces(140, [], [desktop]), [
    { src: 'take', from: 0, to: 100 },
    { src: 'clip', clip: 'popup', from: 100, to: 116 },
    { src: 'take', from: 116, to: 140 },
  ])
})

test('a take without a desktop clip is one piece', () => {
  assert.deepEqual(planPieces(50, []), [{ src: 'take', from: 0, to: 50 }])
})

test('waits are shortened to 1 s and say what was waited for and how long', () => {
  const pieces = planPieces(140, [{ from: 10, to: 20, what: 'waiting for the model' }, ...takeWaits([{ from_ms: 30_000, to_ms: 52_000, what: 'the process monitor\'s next check' }])], [desktop])
  assert.deepEqual(pieces[1], { src: 'take', from: 10, to: 11, label: 'waiting for the model: 10 s, shortened to 1 s' })
  assert.deepEqual(pieces[3], { src: 'take', from: 30, to: 31, label: 'the process monitor\'s next check: 22 s, shortened to 1 s' })
  assert.equal(pieces.filter((p) => p.src === 'clip').length, 1)
})

test('a two-pass wait is labelled with its first-pass length, even when the replay was short', () => {
  const pieces = planPieces(30, takeWaits([{ from_ms: 10_000, to_ms: 11_500, what: 'the model', real_s: 41 }]))
  assert.deepEqual(pieces[1], { src: 'take', from: 10, to: 11, label: 'the model: 41 s in the first pass, replayed in 1 s' })
})

test('a short wait is kept as it is', () => {
  assert.deepEqual(takeWaits([{ from_ms: 0, to_ms: 2_500, what: 'x' }]), [])
})

test('a wait that overlaps a desktop clip is dropped, never cut twice', () => {
  const pieces = planPieces(140, takeWaits([{ from_ms: 110_000, to_ms: 125_000, what: 'the process monitor\'s next check' }]), [desktop])
  assert.deepEqual(pieces.map((p) => p.src), ['take', 'clip', 'take'])
})

test('model waits are found only inside a chat turn, between events', () => {
  const events = [
    { type: 'request', t_ms: 0 },
    { type: 'tool_call', t_ms: 9_000 },
    { type: 'done', t_ms: 10_000 },
    { type: 'confirm', t_ms: 30_000 },
  ]
  assert.deepEqual(findGaps(events, []), [{ from: 0.8, to: 9, what: 'waiting for the model' }])
})

test('times map onto the cut video; a time inside a shortened wait stays inside it', () => {
  const pieces = planPieces(60, [{ from: 10, to: 20 }])
  const map = mapper(pieces, [10, 1, 40])
  assert.equal(map(5_000), 5_000)
  assert.equal(map(15_000), 11_000)
  assert.equal(map(25_000), 16_000)
})

test('the zoom crop stays inside the capture, in the stage aspect ratio', () => {
  const crop = zoomRect({ width: 1920, height: 982 }, { factor: 2.5, cx: 0.5, cy: 0.9 })
  assert.ok(crop.x >= 0 && crop.x + crop.w <= 1920)
  assert.ok(crop.y >= 0 && crop.y + crop.h <= 982)
  assert.ok(Math.abs(crop.w / crop.h - 2) < 0.02)
})

test('srt numbers the cues and formats the times', () => {
  assert.equal(srt([{ start_ms: 1500, end_ms: 62_000, subtitle: 'Hi' }]), '1\n00:00:01,500 --> 00:01:02,000\nHi\n')
})
