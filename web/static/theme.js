/* Theme switch shared by the console and the settings editor.
   Cycles System -> Light -> Dark. The choice is a per-browser convenience kept in localStorage;
   when storage is blocked it still works for the current page. Loaded in <head> so the theme is
   applied before the first paint. */
(function () {
  var KEY = 'wsm-theme';
  var ORDER = ['system', 'light', 'dark'];
  var ICON = { system: 'monitor', light: 'sun', dark: 'moon' };
  var memory = null;

  function get() {
    if (memory) return memory;
    try { memory = localStorage.getItem(KEY) || 'system'; } catch (e) { memory = 'system'; }
    if (ORDER.indexOf(memory) < 0) memory = 'system';
    return memory;
  }
  function apply(mode) {
    var root = document.documentElement;
    if (mode === 'system') root.removeAttribute('data-theme');
    else root.setAttribute('data-theme', mode);
  }
  function paintButtons() {
    var mode = get();
    var label = 'Theme: ' + mode.charAt(0).toUpperCase() + mode.slice(1) + ' (click to change)';
    var buttons = document.querySelectorAll('[data-theme-toggle]');
    for (var i = 0; i < buttons.length; i++) {
      var use = buttons[i].querySelector('use');
      // keep the page's own sprite path (/static/ in the console, web/static/ in the editor)
      if (use) use.setAttribute('href', (use.getAttribute('href') || '').split('#')[0] + '#i-' + ICON[mode]);
      buttons[i].title = label;
      buttons[i].setAttribute('aria-label', label);
    }
  }
  function cycle() {
    memory = ORDER[(ORDER.indexOf(get()) + 1) % ORDER.length];
    try { localStorage.setItem(KEY, memory); } catch (e) { /* not remembered; still applied */ }
    apply(memory);
    paintButtons();
  }

  apply(get());
  window.WSMTheme = { get: get, cycle: cycle };
  document.addEventListener('DOMContentLoaded', function () {
    paintButtons();
    var buttons = document.querySelectorAll('[data-theme-toggle]');
    for (var i = 0; i < buttons.length; i++) buttons[i].addEventListener('click', cycle);
  });
})();
