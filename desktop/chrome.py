"""Custom window chrome for the G2 Hub desktop app (frameless pywebview window on GTK).

The window has no system title bar. Instead a slim title bar in the hub's terminal look is
injected into every page the window shows (the hub page and the desktop app's own start-up and
error screens):

    [>_] G2 HUB / OVERVIEW  ..........drag..........  [* WORK G2  [##] 77%]  [-] [[]] [x]

* The CSS and JS are added as WebKit *user* style sheet / script, so they apply from the first
  paint of every page load (no flash of the un-shifted page). The hub's own files are untouched.
* Window actions are a pywebview js_api (window.pywebview.api.minimize() ...), marshalled to
  the GTK main thread. Moving and resizing use Gtk.Window.begin_move_drag / begin_resize_drag
  with the real button-press event (recorded from the web view), so they are native (snapping,
  work on Wayland as well as X11) - pywebview's own drag-region code (.pywebview-drag-region)
  calls Gtk.Window.move(), which Wayland ignores, so the bar does not use it.
  (A separate WebKit script-message handler is not used: pywebview listens to *all* script
  messages and chokes on foreign ones.)
* Keyboard shortcuts: Ctrl+Q quit, Ctrl+W hide to tray, Ctrl+M minimise, F11 full screen,
  Ctrl+1..9 switch the hub's sidebar sections. Browser-ish keys (reload, zoom, print, history
  navigation) are swallowed.
"""
import json
import os
import threading
from pathlib import Path

TITLEBAR_H = 36

HERE = Path(__file__).resolve().parent
PNG_DIR = HERE / 'icons' / 'png'
ICON_SIZES = (16, 24, 32, 48, 64, 128, 256, 512)

# Palette: the hub's :root values (hub/web/page.py). Each var falls back to the hub's own
# variable when the page defines it, so the bar follows the page if the palette is ever tuned.
CHROME_CSS = r"""
:root {
  --g2tb-h: %(h)dpx;
  --g2tb-bg: #000000; --g2tb-panel: var(--panel, #061006); --g2tb-panel2: var(--panel2, #0a1a0a);
  --g2tb-border: var(--border, #1a5c1a); --g2tb-text: var(--text, #4dff7a); --g2tb-dim: var(--dim, #5fb87f);
  --g2tb-bright: var(--bright, #a8ffc0); --g2tb-red: var(--red, #ff6b6b); --g2tb-amber: var(--amber, #ffd23f);
  --g2tb-glow: 0 0 4px rgba(77,255,122,0.35);
  --g2tb-font: 'JetBrains Mono', ui-monospace, 'SF Mono', Menlo, Consolas, monospace;
}
html.g2tb-on { padding-top: var(--g2tb-h) !important; box-sizing: border-box; }
html.g2tb-on body.g2tb-fitmin { min-height: calc(100vh - var(--g2tb-h)) !important; }
/* The hub's app shell is exactly one viewport tall; take the bar's height off it. The hub page
   sizes .app and the live log from --app-h; the .app rule also covers older hub pages. */
html.g2tb-on { --app-h: calc(100vh - var(--g2tb-h)); }
html.g2tb-on .app { height: calc(100vh - var(--g2tb-h)) !important; }
html.g2tb-on .g2tb-fit { height: calc(100vh - var(--g2tb-h)) !important; max-height: calc(100vh - var(--g2tb-h)) !important; }

/* App-like chrome: no text selection on navigation / controls (content stays selectable). */
html.g2tb-on button, html.g2tb-on .side, html.g2tb-on .nav-btn, html.g2tb-on .topbar,
html.g2tb-on .brand, html.g2tb-on .tabs, html.g2tb-on label, html.g2tb-on .badge,
html.g2tb-on .chip, html.g2tb-on h1, html.g2tb-on h2 { -webkit-user-select: none; user-select: none; }
html.g2tb-on img, html.g2tb-on a { -webkit-user-drag: none; }

#g2tb, #g2tb * { box-sizing: border-box; }
#g2tb {
  position: fixed; top: 0; left: 0; right: 0; height: var(--g2tb-h); z-index: 2147483000;
  display: flex; align-items: stretch; margin: 0; padding: 0;
  background:
    repeating-linear-gradient(0deg, rgba(0,255,65,0.03) 0px, rgba(0,255,65,0.03) 1px, transparent 1px, transparent 3px),
    linear-gradient(180deg, #081608 0%%, #030a03 100%%);
  border-bottom: 1px solid var(--g2tb-border);
  box-shadow: 0 1px 0 rgba(77,255,122,0.05), 0 4px 14px rgba(0,0,0,0.55);
  color: var(--g2tb-text); font: 500 12px/1 var(--g2tb-font);
  -webkit-user-select: none; user-select: none; cursor: default;
}
#g2tb .g2tb-left { display: flex; align-items: center; gap: 10px; padding-left: 10px; min-width: 0; flex: 1 1 auto; }
#g2tb .g2tb-logo {
  flex: 0 0 auto; width: 22px; height: 22px; border-radius: 3px; background: var(--g2tb-panel2);
  border: 1px solid var(--g2tb-text); box-shadow: var(--g2tb-glow); color: var(--g2tb-bright);
  display: flex; align-items: center; justify-content: center; font: 700 10.5px/1 var(--g2tb-font); letter-spacing: -0.5px;
}
#g2tb .g2tb-title { display: flex; align-items: baseline; gap: 8px; min-width: 0; white-space: nowrap; overflow: hidden; }
#g2tb .g2tb-name { font-weight: 700; font-size: 12px; letter-spacing: 0.12em; text-transform: uppercase;
  color: var(--g2tb-text); text-shadow: var(--g2tb-glow); }
#g2tb .g2tb-sep { color: var(--g2tb-border); }
#g2tb .g2tb-page { color: var(--g2tb-dim); font-size: 11px; letter-spacing: 0.08em; text-transform: uppercase;
  overflow: hidden; text-overflow: ellipsis; }
#g2tb .g2tb-page:empty, #g2tb .g2tb-page:empty ~ *, #g2tb .g2tb-sep.g2tb-hide { display: none; }
#g2tb .g2tb-right { display: flex; align-items: center; flex: 0 0 auto; }
#g2tb .g2tb-pill {
  display: flex; align-items: center; gap: 7px; height: 22px; padding: 0 10px; margin-right: 10px;
  background: var(--g2tb-bg); border: 1px solid var(--g2tb-border); border-radius: 3px;
  color: var(--g2tb-dim); font-size: 10.5px; letter-spacing: 0.07em; text-transform: uppercase; white-space: nowrap;
}
#g2tb .g2tb-pill b { font-weight: 500; color: var(--g2tb-text); }
#g2tb .g2tb-dot { width: 7px; height: 7px; border-radius: 50%%; background: var(--g2tb-red); box-shadow: 0 0 6px var(--g2tb-red); }
#g2tb .g2tb-pill.ok .g2tb-dot { background: var(--g2tb-text); box-shadow: 0 0 6px var(--g2tb-text); }
#g2tb .g2tb-pill.wait .g2tb-dot { background: var(--g2tb-amber); box-shadow: 0 0 6px var(--g2tb-amber); animation: g2tb-blink 1.2s steps(2) infinite; }
#g2tb .g2tb-bat { display: none; align-items: center; gap: 5px; color: var(--g2tb-bright); }
#g2tb .g2tb-pill.has-bat .g2tb-bat { display: flex; }
#g2tb .g2tb-cell { position: relative; width: 18px; height: 9px; border: 1px solid var(--g2tb-dim); border-radius: 2px; padding: 1px; }
#g2tb .g2tb-cell::after { content: ''; position: absolute; right: -3px; top: 2px; width: 2px; height: 3px; background: var(--g2tb-dim); border-radius: 0 1px 1px 0; }
#g2tb .g2tb-cell i { display: block; height: 100%%; width: 50%%; background: var(--g2tb-text); box-shadow: var(--g2tb-glow); }
#g2tb .g2tb-pill.low .g2tb-cell i { background: var(--g2tb-red); box-shadow: none; }
#g2tb .g2tb-chg { display: none; color: var(--g2tb-amber); }
#g2tb .g2tb-pill.charging .g2tb-chg { display: inline; }
#g2tb .g2tb-btns { display: flex; align-items: stretch; height: 100%%; border-left: 1px solid var(--g2tb-border); }
#g2tb .g2tb-btn {
  all: unset; box-sizing: border-box; width: 46px; height: 100%%; display: flex; align-items: center; justify-content: center;
  color: var(--g2tb-dim); cursor: default; transition: background 0.12s, color 0.12s;
}
#g2tb .g2tb-btn svg { width: 10px; height: 10px; overflow: visible; }
#g2tb .g2tb-btn svg * { fill: none; stroke: currentColor; stroke-width: 1.3; shape-rendering: crispEdges; }
#g2tb .g2tb-btn:hover { background: var(--g2tb-panel2); color: var(--g2tb-bright); }
#g2tb .g2tb-btn:hover svg { filter: drop-shadow(0 0 3px rgba(77,255,122,0.6)); }
#g2tb .g2tb-btn:active { background: #0f2a0f; }
#g2tb .g2tb-btn.g2tb-close:hover { background: #3a0e0e; color: #ffb3b3; }
#g2tb .g2tb-btn.g2tb-close:hover svg { filter: drop-shadow(0 0 3px rgba(255,107,107,0.7)); }
#g2tb .g2tb-btn.g2tb-close:active { background: #5a1414; }
#g2tb .g2tb-btn .g2tb-restore { display: none; }
html.g2tb-max #g2tb .g2tb-btn .g2tb-maxi { display: none; }
html.g2tb-max #g2tb .g2tb-btn .g2tb-restore { display: inline; }
#g2tb-frame { position: fixed; inset: 0; border: 1px solid var(--g2tb-border); pointer-events: none; z-index: 2147483001; }
html.g2tb-max #g2tb-frame, html.g2tb-max .g2tb-rz { display: none; }
.g2tb-rz { position: fixed; z-index: 2147483002; background: transparent; }
.g2tb-rz[data-edge=n]  { top: 0; left: 10px; right: 10px; height: 4px; cursor: n-resize; }
.g2tb-rz[data-edge=s]  { bottom: 0; left: 10px; right: 10px; height: 5px; cursor: s-resize; }
.g2tb-rz[data-edge=w]  { left: 0; top: 10px; bottom: 10px; width: 5px; cursor: w-resize; }
.g2tb-rz[data-edge=e]  { right: 0; top: 10px; bottom: 10px; width: 5px; cursor: e-resize; }
.g2tb-rz[data-edge=nw] { top: 0; left: 0; width: 10px; height: 10px; cursor: nw-resize; }
.g2tb-rz[data-edge=ne] { top: 0; right: 0; width: 10px; height: 10px; cursor: ne-resize; }
.g2tb-rz[data-edge=sw] { bottom: 0; left: 0; width: 12px; height: 12px; cursor: sw-resize; }
.g2tb-rz[data-edge=se] { bottom: 0; right: 0; width: 12px; height: 12px; cursor: se-resize; }
@keyframes g2tb-blink { 50%% { opacity: 0.35; } }
""" % {'h': TITLEBAR_H}

CHROME_JS = r"""
(function () {
  if (window.__g2tb || !document.documentElement) return;
  var root = document.documentElement;
  var MAX_SECTIONS = 9;

  // Window actions go to Python through pywebview's js_api (window.pywebview.api). The API is
  // injected when the page has finished loading, so anything earlier is queued until then.
  var queue = [];
  function api() {
    var a = window.pywebview && window.pywebview.api;
    return a && typeof a.toggle_maximize === 'function' ? a : null;
  }
  function act(name, arg) {
    var a = api();
    if (!a) { if (queue.length < 20) queue.push([name, arg]); return; }
    try { a[name](arg === undefined ? null : arg); } catch (e) {}
  }
  function flush() {
    if (!api()) return;
    var q = queue; queue = [];
    q.forEach(function (x) { act(x[0], x[1]); });
  }
  window.addEventListener('pywebviewready', flush);
  var polls = 0, poller = setInterval(function () {
    if (api() || ++polls > 100) { clearInterval(poller); flush(); }
  }, 100);

  var SVG = {
    min: '<svg viewBox="0 0 10 10"><line x1="0" y1="5.5" x2="10" y2="5.5"/></svg>',
    max: '<svg viewBox="0 0 10 10"><g class="g2tb-maxi"><rect x="0.5" y="0.5" width="9" height="9"/></g>' +
         '<g class="g2tb-restore"><rect x="0.5" y="2.5" width="7" height="7"/><polyline points="2.5,2.5 2.5,0.5 9.5,0.5 9.5,7.5 7.5,7.5"/></g></svg>',
    close: '<svg viewBox="0 0 10 10"><line x1="0.5" y1="0.5" x2="9.5" y2="9.5" style="shape-rendering:geometricPrecision"/>' +
           '<line x1="9.5" y1="0.5" x2="0.5" y2="9.5" style="shape-rendering:geometricPrecision"/></svg>'
  };

  function build() {
    if (document.getElementById('g2tb') || !document.body) return;
    root.classList.add('g2tb-on');
    var bar = document.createElement('div');
    bar.id = 'g2tb';
    bar.innerHTML =
      '<div class="g2tb-left g2tb-drag">' +
        '<div class="g2tb-logo">&gt;_</div>' +
        '<div class="g2tb-title"><span class="g2tb-name">G2 Hub</span>' +
        '<span class="g2tb-sep g2tb-hide">/</span><span class="g2tb-page"></span></div>' +
      '</div>' +
      '<div class="g2tb-right g2tb-drag">' +
        '<div class="g2tb-pill wait" title="Starting"><span class="g2tb-dot"></span><b class="g2tb-txt">Starting</b>' +
        '<span class="g2tb-bat"><span class="g2tb-cell"><i></i></span><span class="g2tb-pct"></span><span class="g2tb-chg">&#x26A1;</span></span></div>' +
        '<div class="g2tb-btns">' +
          '<button class="g2tb-btn g2tb-min" title="Minimise" data-a="minimize">' + SVG.min + '</button>' +
          '<button class="g2tb-btn g2tb-maxbtn" title="Maximise" data-a="toggle_maximize">' + SVG.max + '</button>' +
          '<button class="g2tb-btn g2tb-close" title="Close" data-a="close">' + SVG.close + '</button>' +
        '</div>' +
      '</div>';
    document.body.appendChild(bar);
    var frame = document.createElement('div');
    frame.id = 'g2tb-frame';
    document.body.appendChild(frame);
    ['n', 's', 'e', 'w', 'nw', 'ne', 'sw', 'se'].forEach(function (edge) {
      var h = document.createElement('div');
      h.className = 'g2tb-rz'; h.dataset.edge = edge;
      h.addEventListener('mousedown', function (ev) {
        if (ev.button !== 0) return;
        ev.preventDefault(); ev.stopPropagation();
        act('start_resize', edge);
      });
      document.body.appendChild(h);
    });

    bar.querySelectorAll('.g2tb-btn').forEach(function (b) {
      b.addEventListener('mousedown', function (ev) { ev.stopPropagation(); });
      b.addEventListener('dblclick', function (ev) { ev.stopPropagation(); });
      b.addEventListener('click', function (ev) { ev.preventDefault(); act(b.dataset.a); });
    });

    // Drag to move (after a few pixels, so a double-click still reaches us), double-click to maximise.
    var press = null;
    bar.addEventListener('mousedown', function (ev) {
      if (ev.button !== 0 || !ev.target.closest('.g2tb-drag')) return;
      ev.preventDefault();
      press = {x: ev.screenX, y: ev.screenY};
    });
    window.addEventListener('mousemove', function (ev) {
      if (!press) return;
      if (!(ev.buttons & 1)) { press = null; return; }
      if (Math.abs(ev.screenX - press.x) + Math.abs(ev.screenY - press.y) > 3) {
        press = null;
        act('start_move');
      }
    }, true);
    window.addEventListener('mouseup', function () { press = null; }, true);
    bar.addEventListener('dblclick', function (ev) {
      if (ev.target.closest('.g2tb-drag')) { ev.preventDefault(); act('toggle_maximize'); }
    });

    trackPageTitle();
    fitViewportBlocks();
    window.addEventListener('resize', fitViewportBlocks);
    labelSections();
    act('hello');
  }

  // "G2 HUB / <section>" from the hub's page title element, if it has one.
  function trackPageTitle() {
    var out = document.querySelector('#g2tb .g2tb-page'), sep = document.querySelector('#g2tb .g2tb-sep');
    function sync() {
      var src = document.getElementById('pageTitle');
      var t = src ? (src.textContent || '').trim() : '';
      out.textContent = t;
      sep.classList.toggle('g2tb-hide', !t);
    }
    sync();
    var src = document.getElementById('pageTitle');
    if (src) new MutationObserver(sync).observe(src, {childList: true, characterData: true, subtree: true});
    else setTimeout(function () { if (document.getElementById('pageTitle')) trackPageTitle(); }, 1500);
  }

  // Any top-level block the page sized to exactly one viewport would now overflow by the bar's height.
  function fitViewportBlocks() {
    var vh = window.innerHeight;
    var body = document.body;
    if (!body.classList.contains('g2tb-fitmin') && parseFloat(getComputedStyle(body).minHeight) >= vh - 1)
      body.classList.add('g2tb-fitmin');
    Array.prototype.forEach.call(document.body.children, function (el) {
      if (el.id && el.id.indexOf('g2tb') === 0) return;
      if (el.classList.contains('g2tb-fit')) return;
      var cs = getComputedStyle(el);
      if (cs.position === 'fixed' || cs.display === 'none') return;
      if (Math.abs(el.getBoundingClientRect().height - vh) < 2) el.classList.add('g2tb-fit');
    });
  }

  function sectionButtons() {
    var list = document.querySelectorAll('#nav .nav-btn');
    if (!list.length) list = document.querySelectorAll('.nav-btn, .tab-btn, [data-sec]');
    return Array.prototype.slice.call(list, 0, MAX_SECTIONS);
  }
  function labelSections() {
    var tries = 0;
    (function tick() {
      var btns = sectionButtons();
      if (!btns.length && tries++ < 10) return setTimeout(tick, 500);
      btns.forEach(function (b, i) { if (!b.title) b.title = 'Ctrl+' + (i + 1); });
    })();
  }

  // ---- keyboard: app shortcuts, and swallow browser-ish keys ----
  window.addEventListener('keydown', function (ev) {
    var k = (ev.key || '').toLowerCase(), ctrl = ev.ctrlKey || ev.metaKey;
    function eat() { ev.preventDefault(); ev.stopPropagation(); }
    if (ctrl && !ev.altKey && k === 'q') { eat(); act('quit'); return; }
    if (ctrl && !ev.altKey && k === 'w') { eat(); act('hide'); return; }
    if (ctrl && !ev.altKey && !ev.shiftKey && k === 'm') { eat(); act('minimize'); return; }
    if (k === 'f11') { eat(); act('toggle_fullscreen'); return; }
    if (ctrl && !ev.altKey && !ev.shiftKey && /^[1-9]$/.test(ev.key)) {
      var b = sectionButtons()[parseInt(ev.key, 10) - 1];
      if (b) { eat(); b.click(); }
      return;
    }
    if (k === 'f5' || (ctrl && (k === 'r' || k === 'p' || k === 'u' || k === 's' || k === 'o' ||
                                k === '+' || k === '=' || k === '-' || k === '0')) ||
        (ev.altKey && (k === 'arrowleft' || k === 'arrowright' || k === 'home')) ||
        k === 'browserback' || k === 'browserforward') {
      eat();
    }
  }, true);
  window.addEventListener('wheel', function (ev) { if (ev.ctrlKey) ev.preventDefault(); }, {passive: false, capture: true});

  // Links to other sites open in the default browser instead of replacing the app's page.
  document.addEventListener('click', function (ev) {
    var a = ev.target.closest && ev.target.closest('a[href]');
    if (!a || ev.defaultPrevented) return;
    var url;
    try { url = new URL(a.getAttribute('href'), location.href); } catch (e) { return; }
    if ((url.protocol === 'http:' || url.protocol === 'https:') && url.origin !== location.origin) {
      ev.preventDefault();
      act('open_external', url.href);
    }
  }, true);

  // ---- state pushed from the app ----
  function setStatus(s) {
    var pill = document.querySelector('#g2tb .g2tb-pill');
    if (!pill || !s) return;
    pill.className = 'g2tb-pill ' + (s.kind || 'err');
    pill.title = s.tooltip || s.text || '';
    pill.querySelector('.g2tb-txt').textContent = s.text || '';
    if (s.battery !== undefined && s.battery !== null) {
      var pct = Math.max(0, Math.min(100, +s.battery));
      pill.classList.add('has-bat');
      if (pct <= 15) pill.classList.add('low');
      if (s.charging) pill.classList.add('charging');
      pill.querySelector('.g2tb-cell i').style.width = pct + '%';
      pill.querySelector('.g2tb-pct').textContent = pct + '%';
    }
  }
  function set(st) {
    st = st || {};
    if ('maximized' in st || 'fullscreen' in st) {
      var big = !!(st.maximized || st.fullscreen);
      root.classList.toggle('g2tb-max', big);
      var mb = document.querySelector('#g2tb .g2tb-maxbtn');
      if (mb) mb.title = big ? 'Restore' : 'Maximise';
    }
    if (st.status) setStatus(st.status);
  }

  window.__g2tb = {set: set, act: act};
  if (document.body) build();
  else document.addEventListener('DOMContentLoaded', build);
  if (window.__g2tbPending) { set(window.__g2tbPending); delete window.__g2tbPending; }
})();
"""


def status_view(state, phase=None):
    """Title-bar pill contents from a poll snapshot (see g2hub_desktop.poll_state).
    phase: 'starting' / 'error' while the desktop app shows its own screens."""
    from tray import describe
    if phase == 'starting':
        return {'kind': 'wait', 'text': 'Starting', 'tooltip': 'Starting the hub server'}
    if phase == 'error' or not (state or {}).get('reachable'):
        return {'kind': 'err', 'text': 'Hub offline', 'tooltip': 'The hub server is not answering'}
    line = describe(state)[0]
    name = state.get('active_name') or 'Glasses'
    if not state.get('connected'):
        link = state.get('link')
        if link == 'disabled':
            return {'kind': 'err', 'text': 'No Bluetooth', 'tooltip': line}
        if link == 'paused':
            adapter = 'adapter' in (state.get('paused') or [])
            return {'kind': 'err', 'text': f'{name} · ' + ('Bluetooth off' if adapter else 'paused'), 'tooltip': line}
        if state.get('reconnecting'):
            return {'kind': 'wait', 'text': 'Reconnecting…', 'tooltip': f'{name}: reconnecting'}
        return {'kind': 'err', 'text': f'{name} · offline', 'tooltip': line}
    return {'kind': 'ok', 'text': name, 'tooltip': line, 'battery': state.get('battery'),
            'charging': bool(state.get('charging'))}


def js_call(state):
    """JS that applies a state dict to the title bar (queued if the bar script hasn't run yet)."""
    payload = json.dumps(state)
    return (f'(function(s){{if(window.__g2tb)window.__g2tb.set(s);'
            f'else window.__g2tbPending=Object.assign(window.__g2tbPending||{{}},s);}})({payload});')


def inline_html():
    """<style>+<script> block for pages built by the desktop app (used when not on GTK)."""
    return f'<style>{CHROME_CSS}</style><script>{CHROME_JS}</script>'


class ChromeApi:
    """pywebview js_api: window.pywebview.api.<name>(). Every call is marshalled to the GTK thread."""

    def __init__(self, chrome):
        self._chrome = chrome

    def minimize(self, _arg=None):
        self._chrome.request('minimize')

    def toggle_maximize(self, _arg=None):
        self._chrome.request('toggle_maximize')

    def toggle_fullscreen(self, _arg=None):
        self._chrome.request('toggle_fullscreen')

    def close(self, _arg=None):
        self._chrome.request('close')

    def hide(self, _arg=None):
        self._chrome.request('hide')

    def quit(self, _arg=None):
        self._chrome.request('quit')

    def start_move(self, _arg=None):
        self._chrome.request('start_move')

    def start_resize(self, edge=None):
        self._chrome.request('start_resize', edge)

    def hello(self, _arg=None):
        self._chrome.request('hello')

    def open_external(self, url=None):
        self._chrome.request('open_external', url)

    def state(self, _arg=None):
        return self._chrome.snapshot()


class WindowChrome:
    """GTK glue for the frameless window.

    hooks: hide() - hide to tray (or minimise), quit() - quit the app, open_external(url),
           geometry_changed() - window moved/resized/maximised (for saving it).
    Call attach() on the GTK main thread before the first page loads (window.events.before_show).
    """

    EDGES = {'n': 'NORTH', 's': 'SOUTH', 'e': 'EAST', 'w': 'WEST',
             'nw': 'NORTH_WEST', 'ne': 'NORTH_EAST', 'sw': 'SOUTH_WEST', 'se': 'SOUTH_EAST'}

    def __init__(self, window, hooks, log=print):
        self.window = window
        self.hooks = hooks
        self.log = log
        self.api = ChromeApi(self)
        self.native = None          # Gtk.ApplicationWindow
        self.webview = None         # WebKit2.WebView
        self.visible = True
        self._press = None          # last button press on the web view: (button, x_root, y_root, time)
        self._state = {'maximized': False, 'fullscreen': False,
                       'status': status_view({}, 'starting')}
        self._lock = threading.Lock()
        self._GLib = self._Gdk = None

    # ---------------------------------------------------------------- setup (GTK thread)
    def attach(self):
        import gi
        gi.require_version('Gdk', '3.0')
        from gi.repository import Gdk, GLib
        from webview.platforms.gtk import BrowserView, webkit
        self._GLib, self._Gdk = GLib, Gdk
        bv = BrowserView.instances.get(self.window.uid)
        if bv is None:
            raise RuntimeError('pywebview GTK window not found')
        self.native, self.webview = bv.window, bv.webview

        mgr = bv.manager
        mgr.add_style_sheet(webkit.UserStyleSheet(
            CHROME_CSS, webkit.UserContentInjectedFrames.TOP_FRAME,
            webkit.UserStyleLevel.USER, None, None))
        mgr.add_script(webkit.UserScript(
            CHROME_JS, webkit.UserContentInjectedFrames.TOP_FRAME,
            webkit.UserScriptInjectionTime.END, None, None))

        self.webview.connect('button-press-event', self._on_press)
        self.native.connect('window-state-event', self._on_state)
        self.native.connect('configure-event', lambda *_: self._geometry_changed())
        self.native.connect('show', lambda *_: setattr(self, 'visible', True))
        self.native.connect('hide', lambda *_: setattr(self, 'visible', False))
        self._set_icons()

    def _set_icons(self):
        from gi.repository import GdkPixbuf
        pbs = []
        for s in ICON_SIZES:
            p = PNG_DIR / f'g2hub-{s}.png'
            if p.exists():
                try:
                    pbs.append(GdkPixbuf.Pixbuf.new_from_file(str(p)))
                except Exception:  # noqa: BLE001
                    pass
        if pbs:
            from gi.repository import Gtk
            self.native.set_icon_list(pbs)
            Gtk.Window.set_default_icon_list(pbs)

    # ---------------------------------------------------------------- events (GTK thread)
    def _on_press(self, _widget, ev):
        self._press = (ev.button, ev.x_root, ev.y_root, ev.time)
        return False

    def _on_state(self, _w, ev):
        ws = ev.new_window_state
        Gdk = self._Gdk
        if os.environ.get('G2HUB_CHROME_DEBUG'):
            self.log(f'window state {ws.value_names}')
        self._state['maximized'] = bool(ws & (Gdk.WindowState.MAXIMIZED | Gdk.WindowState.TILED))
        self._state['fullscreen'] = bool(ws & Gdk.WindowState.FULLSCREEN)
        self._run_js(js_call({'maximized': self._state['maximized'], 'fullscreen': self._state['fullscreen']}))
        self._geometry_changed()
        return False

    def _geometry_changed(self):
        cb = self.hooks.get('geometry_changed')
        if cb:
            cb()
        return False

    # ---------------------------------------------------------------- actions
    def request(self, action, arg=None):
        """Thread-safe: run an action on the GTK thread."""
        if self._GLib is None:
            return
        self._GLib.idle_add(lambda: (self.dispatch(action, arg), False)[1])

    def dispatch(self, action, arg=None):
        """GTK thread only."""
        if os.environ.get("G2HUB_CHROME_DEBUG"):
            self.log(f"chrome action {action} {arg!r}")
        w = self.native
        if w is None:
            return
        Gdk = self._Gdk
        if action == 'hello':
            self._run_js(js_call(self.snapshot()))
        elif action == 'minimize':
            w.iconify()
        elif action == 'toggle_maximize':
            if self._state['fullscreen']:
                w.unfullscreen()
            elif w.is_maximized():
                w.unmaximize()
            else:
                w.maximize()
        elif action == 'toggle_fullscreen':
            if self._state['fullscreen']:
                w.unfullscreen()
            else:
                w.fullscreen()
        elif action == 'close':
            w.close()                               # same path as the window manager's close
        elif action in ('hide', 'quit'):
            threading.Thread(target=self.hooks[action], name=f'chrome-{action}', daemon=True).start()
        elif action == 'open_external' and isinstance(arg, str) and arg.startswith(('http://', 'https://')):
            threading.Thread(target=self.hooks['open_external'], args=(arg,), daemon=True).start()
        elif action == 'start_move':
            btn, x, y, t = self._press_or_pointer()
            w.begin_move_drag(btn, x, y, t)
        elif action == 'start_resize' and arg in self.EDGES:
            if w.is_maximized() or self._state['fullscreen']:
                return
            btn, x, y, t = self._press_or_pointer()
            w.begin_resize_drag(getattr(Gdk.WindowEdge, self.EDGES[arg]), btn, x, y, t)

    def _press_or_pointer(self):
        if self._press:
            return self._press
        Gdk = self._Gdk
        seat = Gdk.Display.get_default().get_default_seat()
        _screen, x, y = seat.get_pointer().get_position()
        return 1, x, y, Gdk.CURRENT_TIME

    # ---------------------------------------------------------------- state pushes (any thread)
    def snapshot(self):
        with self._lock:
            return dict(self._state)

    def set_status(self, status):
        with self._lock:
            self._state['status'] = status
        self._run_js(js_call({'status': status}))

    def _run_js(self, script):
        if self._GLib is None or self.webview is None:
            return

        def run():
            try:
                self.webview.evaluate_javascript(script, -1, None, None, None, None, None)
            except (AttributeError, TypeError):
                self.webview.run_javascript(script, None, None, None)
            return False
        self._GLib.idle_add(run)
