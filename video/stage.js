// The stage's own behaviour: no app logic, no data of its own. record.spec.ts calls
// window.stage.* with cues built from the take's capture (ported from hl-bead-studio/video).
;(() => {
  const $ = (id) => document.getElementById(id)
  const LAYERS = ['Config', 'Monitors', 'State files', 'Console', 'Agent', 'Model', 'Tools', 'Check', 'Ticket']
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c])

  function pipeline(active) {
    $('pipeline').innerHTML = LAYERS.map(
      (l, i) => `${i ? '<i>›</i>' : ''}<span class="${l === active ? 'on' : ''}">${esc(l)}</span>`,
    ).join('')
  }

  /** The console in the frame; `path` is the console's own page or a ticket it serves. */
  function loadApp(path = '/') {
    return new Promise((resolve) => {
      const app = $('app')
      app.addEventListener('load', () => resolve(), { once: true })
      app.src = path
    })
  }

  function init({ banner, provider }) {
    $('banner').textContent = banner
    $('provider').textContent = provider
    pipeline(null)
  }

  /** One storyboard row: subtitle, layer, callouts (file:line + excerpt), payload JSON. */
  function show(cue) {
    $('subs').textContent = cue.subtitle || ''
    $('row-id').textContent = cue.id ? `row ${cue.id}` : ''
    if (cue.layer) pipeline(cue.layer)
    $('callouts').innerHTML = (cue.callouts || [])
      .slice(0, cue.payload ? 2 : 3)
      .map((c) => `<div class="callout"><div class="where">${esc(c.file)}:${c.line} · ${esc(c.symbol)}</div><pre>${esc(c.excerpt)}</pre></div>`)
      .join('')
    const box = $('payload')
    if (cue.payload) {
      box.classList.remove('empty')
      $('payload-label').textContent = cue.payload.label
      $('payload-note').textContent = cue.payload.note || ''
      $('payload-json').textContent = JSON.stringify(cue.payload.value, null, 2)
    } else {
      box.classList.add('empty')
    }
    if (cue.slide) slide(cue.slide, cue.slideData)
    else hideSlide()
  }

  const SLIDES = {
    hook: () => `
      <h1>Windows System Monitor</h1>
      <p class="lead">Five PowerShell monitors watch a Windows PC and act on thresholds from one JSON file.
      A small model running on this PC explains an incident and drafts the ticket. The monitors decide;
      the AI explains.</p>`,
    map: () => `
      <h2>The pieces</h2>
      <div class="boxes">
        <div class="box"><b>One JSON file</b><span>What to watch, the thresholds, the actions, the runbooks.</span></div><div class="arrow">→</div>
        <div class="box"><b>Five monitors</b><span>Hidden PowerShell processes. They open incidents and run the actions.</span></div><div class="arrow">→</div>
        <div class="box"><b>State files</b><span>JSON in logs/: the readings and the open incidents.</span></div><div class="arrow">→</div>
        <div class="box hot"><b>Console + assistant</b><span>Reads them. The assistant's tools only read; Ollama runs on this PC.</span></div>
      </div>`,
    eval: (d) => `
      <h2>Monitor data is data, never instructions</h2>
      <p class="lead" style="margin-bottom:20px">${esc(d.scenarios)} incident scenarios, scored from the traces. Failures are published.</p>
      <table class="cmp">
        <tr><th>Run</th><th>Passed</th><th>Held in every run</th></tr>
        ${(d.runs || []).map((r) => `<tr><td>${esc(r.label)}</td><td class="n">${esc(r.passed)}</td><td>${esc(r.held)}</td></tr>`).join('')}
      </table>`,
    end: (d) => `
      <h1>The monitors decide. The AI explains.</h1>
      <p class="lead" style="margin-bottom:34px">Read-only tools, checked numbers, and nothing is sent without your click.</p>
      <p class="lead">${esc(d.repo || '')}</p>
      ${d.author ? `<p class="lead" style="margin-top:34px">${esc(d.author)}</p>` : ''}
      ${d.linkedin ? `<p class="lead">${esc(d.linkedin)}</p>` : ''}`,
  }

  function slide(name, data = {}) {
    $('slide-inner').innerHTML = SLIDES[name](data)
    $('slide').classList.add('on')
  }

  function hideSlide() {
    $('slide').classList.remove('on')
  }

  /** The app frame's text: for the no-paths check. */
  function appText() {
    const doc = $('app').contentDocument
    if (!doc) return ''
    return doc.body.innerText || doc.body.textContent || ''
  }

  window.stage = { init, loadApp, show, slide, hideSlide, appText }
})()
