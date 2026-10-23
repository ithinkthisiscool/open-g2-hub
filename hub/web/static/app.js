const logEl = document.getElementById('log');
const NAV_DIRECTIONS = ["DEPART", "STRAIGHT", "TURN_RIGHT", "TURN_LEFT", "TURN_SLIGHT_RIGHT", "TURN_SLIGHT_LEFT", "TURN_SHARP_RIGHT", "TURN_SHARP_LEFT", "UTURN_CLOCKWISE", "UTURN_COUNTERCLOCKWISE", "ROUNDABOUT_SHARP_RIGHT_CW", "ROUNDABOUT_RIGHT_CCW", "ROUNDABOUT_RIGHT_CW", "ROUNDABOUT_SLIGHT_RIGHT_CCW", "ROUNDABOUT_SLIGHT_RIGHT_CW", "ROUNDABOUT_STRAIGHT_CCW", "ROUNDABOUT_STRAIGHT_CW", "ROUNDABOUT_SLIGHT_LEFT_CCW", "ROUNDABOUT_SLIGHT_LEFT_CW", "ROUNDABOUT_LEFT_CCW", "ROUNDABOUT_LEFT_CW", "ROUNDABOUT_SHARP_LEFT_CCW", "ROUNDABOUT_SHARP_LEFT_CW", "ROUNDABOUT_UTURN_CCW", "ROUNDABOUT_UTURN_CW", "ROUNDABOUT_CCW", "ROUNDABOUT_CW", "ROUNDABOUT_EXIT_CCW", "ROUNDABOUT_EXIT_CW", "MERGE_RIGHT", "MERGE_LEFT", "FORK_RIGHT", "FORK_LEFT", "MERGE_UNSPECIFIED", "ROUNDABOUT_SHARP_RIGHT_CCW"];
const MENU_APPS = [["Dashboard", 1], ["Notifications", 4], ["Translate", 5], ["Teleprompt", 6], ["Even AI", 7], ["Navigate", 8], ["Conversate", 11], ["Terminal", 48], ["Silent mode", 266]];

// ───────────────────────── utilities ─────────────────────────
// Escapes for both element text AND attribute values (quotes included): device names, news and
// task titles come from outside (BLE adverts, RSS, Claude) and are interpolated into attributes.
function escapeHtml(s) {
  return String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
function val(id) { return document.getElementById(id).value; }
function $(id) { return document.getElementById(id); }
// Local API token (hub/auth.py), embedded by the server; required on every POST to /api/*.
const G2HUB_TOKEN = (document.querySelector('meta[name="g2hub-token"]') || {}).content || '';
// Never throws: network errors and non-JSON replies come back as {error}.
async function postJson(url, body) {
  let res;
  try {
    res = await fetch(url, {method: 'POST', headers: {'Content-Type': 'application/json', 'X-G2Hub-Token': G2HUB_TOKEN},
                            body: JSON.stringify(body || {})});
  } catch (e) {
    return {error: 'hub not reachable'};
  }
  let d = null;
  try { d = await res.json(); } catch (e) { d = null; }
  if (d && typeof d === 'object') {
    if (!res.ok && !d.error) d.error = `HTTP ${res.status}`;
    if (res.status === 401) d.error = 'API token rejected: reload the page (the hub may have a new token).';
    return d;
  }
  return res.ok ? {} : {error: `HTTP ${res.status} ${res.statusText || ''}`.trim()};
}
async function getJson(url) {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.json();
}
function fmtAgo(min) {
  if (min < 1) return 'just now';
  if (min < 60) return `${min}m ago`;
  return `${Math.floor(min/60)}h ${min%60}m ago`;
}
function setSyncState(id, state, label) {
  const el = $(id);
  if (!el) return;
  el.className = 'sync ' + state;
  el.textContent = label;
  el.title = label;
}

// ── toasts: short results instead of alerts / raw JSON ──
function toast(msg, kind) {
  const box = $('toasts');
  const t = document.createElement('div');
  t.className = 'toast ' + (kind || 'ok');
  t.setAttribute('role', kind === 'err' ? 'alert' : 'status');
  t.innerHTML = `<span class="msg">${escapeHtml(msg)}</span><button type="button" aria-label="Dismiss">×</button>`;
  t.querySelector('button').addEventListener('click', () => t.remove());
  box.appendChild(t);
  while (box.children.length > 4) box.firstChild.remove();
  setTimeout(() => t.remove(), kind === 'err' ? 8000 : 4000);
}

// ── in-page dialogs: replace native confirm()/prompt(). Both return a Promise. ──
function uiDialog(msg, opts) {
  opts = opts || {};
  return new Promise(resolve => {
    const bg = document.createElement('div');
    bg.className = 'modalBg';
    const field = opts.input ? `<input type="text" id="uiDlgInput" autocomplete="off">` : '';
    bg.innerHTML = `<div class="modal" role="dialog" aria-modal="true" aria-label="${escapeHtml(opts.title || 'Confirm')}">`
      + `<p>${escapeHtml(msg)}</p>${field}`
      + `<div class="row"><button type="button" class="secondary small" data-r="no">Cancel</button>`
      + `<button type="button" class="small ${opts.danger ? 'warn' : ''}" data-r="yes">${escapeHtml(opts.ok || 'OK')}</button></div></div>`;
    const prev = document.activeElement;
    const inp = bg.querySelector('input');
    if (inp) inp.value = opts.value || '';
    const done = (yes) => {
      document.removeEventListener('keydown', onKey, true);
      const v = inp ? inp.value : true;
      bg.remove();
      if (prev && prev.focus) { try { prev.focus(); } catch (e) {} }
      resolve(yes ? v : (inp ? null : false));
    };
    const onKey = (ev) => {
      if (ev.key === 'Escape') { ev.preventDefault(); done(false); }
      else if (ev.key === 'Enter' && inp && document.activeElement === inp) { ev.preventDefault(); done(true); }
    };
    bg.addEventListener('click', (ev) => {
      if (ev.target === bg) done(false);
      const b = ev.target.closest('button[data-r]');
      if (b) done(b.dataset.r === 'yes');
    });
    document.addEventListener('keydown', onKey, true);
    document.body.appendChild(bg);
    (inp || bg.querySelector('button[data-r="yes"]')).focus();
    if (inp) inp.select();
  });
}
function uiConfirm(msg, opts) { return uiDialog(msg, opts); }
function uiPrompt(msg, value, opts) { return uiDialog(msg, Object.assign({input: true, value: value, title: 'Enter a value'}, opts || {})); }

// ── busy state for buttons (works together with the offline state below) ──
function setBusy(btn, on) {
  if (!btn || !btn.tagName) return;
  btn.dataset.busy = on ? '1' : '';
  btn.classList.toggle('busy', !!on);
  btn.setAttribute('aria-busy', on ? 'true' : 'false');
  btn.disabled = !!on || btn.dataset.offline === '1' || !!btn.closest('fieldset[disabled]');
}
// One POST with loading state + toast. ok: text or fn(d) -> text ('' = no toast). Returns d or null.
async function call(btn, url, body, ok, opts) {
  opts = opts || {};
  if (btn && btn.dataset && btn.dataset.busy === '1') return null;
  setBusy(btn, true);
  try {
    const d = await postJson(url, body);
    if (d.error) {
      if (!opts.quietError) toast((opts.what ? opts.what + ': ' : '') + d.error, 'err');
      return null;
    }
    const msg = typeof ok === 'function' ? ok(d) : ok;
    if (msg) toast(msg, 'ok');
    return d;
  } finally {
    setBusy(btn, false);
  }
}

// ───────────────────────── connection state ─────────────────────────
const conn = {hub: true, connected: false, link: '', paused: [], name: '', status: {}, cause: null, hint: null, version: ''};
// [kind, short text, longer explanation] for the status chip, the sidebar pill and the Home hero.
function connView() {
  if (!conn.hub) return ['bad', 'Hub offline', 'The hub server is not answering'];
  if (conn.connected) return ['ok', 'Connected', 'Glasses connected'];
  if (conn.link === 'disabled') return ['warn', 'Bluetooth disabled', 'This hub runs without Bluetooth (G2HUB_NO_BLE=1): web page only, it never connects to glasses'];
  if (conn.link === 'paused') return ['warn', conn.paused.includes('adapter') ? 'Bluetooth off' : 'Paused',
                                      'Connection paused: ' + conn.paused.join(', ')];
  if (conn.link === 'reconnecting') return ['warn', 'Reconnecting…', 'The link dropped; the hub is reconnecting'];
  if (conn.link === 'searching') return ['bad', 'Not connected', 'Not connected; the hub keeps looking for your glasses (take them out of the case, and make sure no phone holds them)'];
  return ['bad', 'Not connected', 'Glasses not connected'];
}
function renderConn() {
  const [kind, text, tip] = connView();
  const dot = $('dot');
  dot.className = 'dot ' + (kind === 'ok' ? 'ok' : kind === 'warn' ? 'warn' : '');
  $('connText').textContent = text;
  dot.parentElement.title = tip;
  const s = conn.status || {};
  let chip = `<span class="dot ${kind === 'ok' ? 'ok' : kind === 'warn' ? 'warn' : ''}"></span>`
    + (conn.name ? `<b>${escapeHtml(conn.name)}</b><span class="sep">·</span>` : '') + escapeHtml(text);
  if (conn.connected && s.battery !== undefined)
    chip += `<span class="sep">·</span><span class="${s.battery <= 15 ? 'bad-t' : s.battery <= 30 ? 'warn-t' : ''}">${escapeHtml(s.battery)}%${s.charging ? ' ⚡' : ''}</span>`;
  $('chips').innerHTML = `<button type="button" class="chip st-${kind}" data-go="home" title="${escapeHtml(tip)}">${chip}</button>`;
  $('hubDown').hidden = conn.hub;
  connPanelRender();
  renderHero();
  if (wiz.open) wizRender();
  applyNeeds();
  tglRender();
}
// Plain-language "what do I do now" panel on Home, driven by /api/status cause + hint.
const CAUSES = {
  no_adapter: ['No Bluetooth adapter found', 'Plug in or turn on a Bluetooth adapter on this computer. The hub carries on by itself.'],
  bluetooth_off: ['Bluetooth is turned off', 'Turn Bluetooth on in your system settings. The hub reconnects once it is on.'],
  paused_suspend: ['Paused while the computer sleeps', 'The hub disconnected your glasses cleanly before sleep and reconnects when the computer wakes.'],
  paused_adapter: ['Paused: Bluetooth is off', 'Turn Bluetooth back on and the hub reconnects by itself.'],
  no_pair_saved: ['No glasses saved yet', 'Follow the setup guide below, or open Glasses and choose Find glasses.'],
  reconnecting: ['Reconnecting to your glasses', 'The link dropped. This usually takes a few seconds.'],
  in_case_or_held: ["Can't reach your glasses",
                    'Take them out of the case, and disconnect them in the Even app on your phone (or close that app). The hub connects as soon as it can see them.'],
};
function connPanelRender() {
  const el = $('connPanel');
  if (!el) return;
  if (!conn.hub || conn.connected || conn.link === 'disabled' || wiz.open) { el.hidden = true; return; }
  const c = CAUSES[conn.cause];
  const title = c ? c[0] : 'Not connected yet';
  const action = c ? c[1] : 'The hub keeps looking for your glasses. Take them out of the case and make sure no phone is connected to them.';
  el.innerHTML = `<b>${escapeHtml(title)}</b><br>${escapeHtml(action)}`;
  el.hidden = false;
}
// Home hero: name, friendly connection line, battery meters (glasses + case), worn / software.
function heroMeter(label, pct, sub, ico) {
  const p = Math.max(0, Math.min(100, Number(pct) || 0));
  const lvl = p <= 15 ? 'bad' : p <= 30 ? 'warn' : '';
  return `<div class="meter ${lvl}"><div class="mTop"><span class="mIco">${svgIco(ico)}</span><span class="mLbl">${escapeHtml(label)}</span>`
    + `<span class="mVal">${escapeHtml(p)}<small>%</small></span></div>`
    + `<div class="mBar" role="meter" aria-label="${escapeHtml(label)} battery" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${p}"><i style="width:${p}%"></i></div>`
    + `<div class="mSub">${escapeHtml(sub || '')}</div></div>`;
}
function renderHero() {
  if (!$('heroState')) return;
  const [kind, text] = connView();
  const s = conn.status || {};
  $('heroName').textContent = conn.name || 'Even G2';
  $('heroKicker').textContent = devList.length ? 'Your glasses' : 'Welcome';
  let line = text;
  if (conn.connected && s.worn !== undefined) line += s.worn ? ' · Worn' : ' · Not worn';
  if (conn.link === 'disabled' && conn.hub) line = 'Bluetooth is disabled for this hub';
  $('heroState').innerHTML = `<span class="dot ${kind === 'ok' ? 'ok' : kind === 'warn' ? 'warn' : ''}"></span><span>${escapeHtml(line)}</span>`;
  $('heroCard').classList.toggle('live', conn.connected);
  const m = [];
  if (s.battery !== undefined) m.push(heroMeter('Glasses', s.battery, conn.connected ? (s.charging ? 'Charging' : 'Battery') : 'Last known', 'glasses'));
  if (s.case_battery !== undefined) m.push(heroMeter('Case', s.case_battery, conn.connected ? (s.case_charging ? 'Charging' : 'Charging case') : 'Last known', 'battery'));
  const fw = s.right_version || s.left_version;
  const facts = [];
  if (fw) facts.push(`Software ${escapeHtml(fw)}`);
  if (s.left_version && s.right_version && s.left_version !== s.right_version) facts.push(`left lens ${escapeHtml(s.left_version)}`);
  $('heroBatt').innerHTML = (m.length ? `<div class="meters${conn.connected ? '' : ' stale'}">${m.join('')}</div>`
    : `<div class="hint flush">${conn.connected ? 'Reading battery…' : 'Battery levels appear here when your glasses connect.'}</div>`)
    + (facts.length ? `<div class="heroFacts">${facts.join(' · ')}</div>` : '');
}
// Everything marked data-needs="glasses" is disabled while the glasses are offline.
function applyNeeds() {
  const off = !(conn.hub && conn.connected);
  document.querySelectorAll('[data-needs="glasses"]').forEach(el => {
    if (el.dataset.title0 === undefined) el.dataset.title0 = el.title || '';
    if (el.tagName === 'FIELDSET') {
      el.disabled = off;
    } else {
      el.dataset.offline = off ? '1' : '';
      el.disabled = off || el.dataset.busy === '1';
    }
    el.title = off ? 'Connect your glasses first' : el.dataset.title0;
  });
  document.querySelectorAll('[data-offline-hint]').forEach(el => { el.hidden = !off; });
}
async function statusLoad() {
  try {
    const d = await getJson('/api/status');
    Object.assign(conn, {hub: true, connected: !!d.connected, link: d.link || '', paused: d.paused || [],
                         cause: d.cause || null, hint: d.hint || null, version: d.version || ''});
    if (conn.version) {
      $('hubVer').textContent = 'Version ' + conn.version;
      $('hubAddr').textContent = location.host + ' · v' + conn.version;
    }
  } catch (e) { conn.hub = false; }
  renderConn();
}

// ───────────────────────── app shell ─────────────────────────
const ICO = {   // 24px line icons (trusted constants, inserted as markup)
  home: '<path d="M4 11l8-7 8 7v8.5a1.5 1.5 0 0 1-1.5 1.5H15v-6H9v6H5.5A1.5 1.5 0 0 1 4 19.5z"/>',
  grid: '<rect x="4" y="4" width="7" height="7" rx="2"/><rect x="13" y="4" width="7" height="7" rx="2"/><rect x="4" y="13" width="7" height="7" rx="2"/><rect x="13" y="13" width="7" height="7" rx="2"/>',
  apps: '<circle cx="7.5" cy="7.5" r="3"/><circle cx="16.5" cy="7.5" r="3"/><circle cx="7.5" cy="16.5" r="3"/><circle cx="16.5" cy="16.5" r="3"/>',
  glasses: '<rect x="2.5" y="8.5" width="8.2" height="7.5" rx="3.4"/><rect x="13.3" y="8.5" width="8.2" height="7.5" rx="3.4"/><path d="M10.7 11.3c.9-.8 1.7-.8 2.6 0"/>',
  gear: '<circle cx="12" cy="12" r="3"/><path d="M12 2.8l1.6 2.3 2.7-.6.6 2.7 2.3 1.6-1.3 2.4 1.3 2.4-2.3 1.6-.6 2.7-2.7-.6L12 21.2l-1.6-2.3-2.7.6-.6-2.7-2.3-1.6L6.1 12 4.8 9.6l2.3-1.6.6-2.7 2.7.6z"/>',
  sliders: '<path d="M4 7h10M18 7h2M4 17h2M10 17h10"/><circle cx="16" cy="7" r="2"/><circle cx="8" cy="17" r="2"/>',
  code: '<path d="M9 8l-4 4 4 4M15 8l4 4-4 4"/>',
  list: '<path d="M5 7h14M5 12h14M5 17h9"/>',
  spark: '<path d="M12 3l2 5.5 5.5 2-5.5 2L12 18l-2-5.5-5.5-2 5.5-2z"/><path d="M18.5 16.5l.8 2 2 .8-2 .8-.8 2-.8-2-2-.8 2-.8z"/>',
  translate: '<path d="M4 5.5h9M8.5 3.5v2M6 5.5c.6 3 2.6 5.6 5.5 7M11 5.5c-.8 3.6-3.2 6.6-6.5 8.2"/><path d="M12.5 20.5l4-9 4 9M14 17.2h5"/>',
  text: '<path d="M5 6h14M5 10h14M5 14h10M5 18h7"/>',
  nav: '<path d="M12 3l7 18-7-4-7 4z"/>',
  puzzle: '<path d="M10 4.5a2 2 0 0 1 4 0V6h4v4h-1.5a2 2 0 0 0 0 4H18v4h-4v-1.5a2 2 0 0 0-4 0V18H6v-4h1.5a2 2 0 0 0 0-4H6V6h4z"/>',
  chart: '<path d="M4 19.5h16M6 15l4-5 3 3 5-7"/>',
  bell: '<path d="M6 16v-5a6 6 0 0 1 12 0v5l1.5 2h-15z"/><path d="M10 20.5a2 2 0 0 0 4 0"/>',
  watch: '<circle cx="12" cy="12" r="6"/><path d="M12 9v3l2 1.5M9 6.6L9.5 3h5l.5 3.6M9 17.4l.5 3.6h5l.5-3.6"/>',
  moon: '<path d="M19 14.5A7.5 7.5 0 0 1 9.5 5a7.5 7.5 0 1 0 9.5 9.5z"/>',
  sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M5.3 18.7l1.4-1.4M17.3 6.7l1.4-1.4"/>',
  headup: '<path d="M12 3v7M8.5 6.5L12 3l3.5 3.5"/><path d="M5 21c.6-3.6 3.5-6 7-6s6.4 2.4 7 6"/>',
  mic: '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21"/>',
  calendar: '<rect x="4" y="5" width="16" height="15" rx="3"/><path d="M4 10h16M8.5 3v4M15.5 3v4"/>',
  check: '<rect x="4" y="4" width="16" height="16" rx="4.5"/><path d="M8.5 12.2l2.4 2.4 4.6-5"/>',
  news: '<rect x="4" y="4" width="16" height="16" rx="3"/><path d="M8 8.5h8M8 12h8M8 15.5h5"/>',
  weather: '<path d="M7.5 18.5h9.5a3.5 3.5 0 0 0 .3-7 5 5 0 0 0-9.6-1.3A4.2 4.2 0 0 0 7.5 18.5z"/>',
  layers: '<path d="M12 4l8.5 4.5L12 13 3.5 8.5z"/><path d="M3.5 12.5L12 17l8.5-4.5M3.5 16.5L12 21l8.5-4.5"/>',
  key: '<circle cx="8" cy="15" r="4"/><path d="M11 12.2L19.5 4M16 7.5l2.5 2.5M14 9.5l2 2"/>',
  palette: '<path d="M12 3.5a8.5 8.5 0 1 0 0 17c1.2 0 1.8-.9 1.4-2-.5-1.3.4-2.5 1.8-2.5H17a3.5 3.5 0 0 0 3.5-3.5c0-5-3.8-9-8.5-9z"/><circle cx="7.8" cy="11" r="1"/><circle cx="10.5" cy="7.5" r="1"/><circle cx="15" cy="8" r="1"/>',
  laptop: '<rect x="5" y="5" width="14" height="10" rx="1.5"/><path d="M2.5 19h19"/>',
  help: '<circle cx="12" cy="12" r="8.5"/><path d="M9.6 9.5a2.5 2.5 0 0 1 4.8.9c0 1.7-2.4 2.1-2.4 3.6M12 17h.01"/>',
  flask: '<path d="M9.5 3.5h5M10.5 3.5V9L5 18.5a1.5 1.5 0 0 0 1.3 2.2h11.4a1.5 1.5 0 0 0 1.3-2.2L13.5 9V3.5"/><path d="M7.5 14.5h9"/>',
  info: '<circle cx="12" cy="12" r="8.5"/><path d="M12 11v5.5M12 7.8h.01"/>',
  heart: '<path d="M12 19.5s-7.5-4.4-7.5-10A4.2 4.2 0 0 1 12 7a4.2 4.2 0 0 1 7.5 2.5c0 5.6-7.5 10-7.5 10z"/>',
  menu: '<rect x="4" y="4" width="6.5" height="6.5" rx="1.8"/><rect x="13.5" y="4" width="6.5" height="6.5" rx="1.8"/><rect x="4" y="13.5" width="6.5" height="6.5" rx="1.8"/><path d="M16.75 14v5.5M14 16.75h5.5"/>',
  battery: '<rect x="3" y="7.5" width="16" height="9" rx="2.5"/><path d="M21.5 10.5v3"/>',
};
const svgIco = (k) => `<svg viewBox="0 0 24 24" aria-hidden="true">${ICO[k] || ''}</svg>`;
// [id, nav label, icon, intro under the title, group]. group 'dev' = only in Developer mode.
// The order is also the desktop app's Ctrl+1… order (desktop/chrome.py reads #nav .nav-btn).
const SECTIONS = [
  ['home', 'Home', 'home', ''],
  ['dashboard', 'Dashboard', 'grid', 'What your glasses show when you look up. Changes sync automatically and are saved for this pair.'],
  ['apps', 'Apps', 'apps', 'Full-screen apps on your glasses.'],
  ['glasses', 'Glasses', 'glasses', 'Your pairs, display, menu and notifications.'],
  ['settings', 'Settings', 'gear', ''],
  ['developer', 'Developer', 'code', 'Low-level tools for protocol work. Nothing here is needed for everyday use; the other sections do it all automatically.', 'dev'],
  ['log', 'Log', 'list', 'Every connection event and message to and from your glasses, live.', 'dev'],
];
// Sub-pages: [section, id, title, one-line description, icon, beta]. Cards with data-page="id" live there;
// the section's landing page shows a tile for each (Apps on Home too).
const PAGES = [
  ['apps', 'even-ai', 'Even AI', 'Ask anything with "Hey Even"', 'spark'],
  ['apps', 'translate', 'Translate', 'Live translation on your lenses', 'translate'],
  ['apps', 'teleprompter', 'Teleprompter', 'Your script, hands-free', 'text'],
  ['apps', 'navigation', 'Navigation', 'Turn-by-turn directions', 'nav'],
  ['apps', 'evenhub', 'EvenHub apps', 'Install third-party apps', 'puzzle', true],
  ['apps', 'widgets', 'Custom widgets', 'Graphs, numbers and charts', 'chart', true],
];
const ALIASES = {overview: 'home', widgets: 'dashboard', assistant: 'apps/even-ai'};   // old #links
const STATUS = {
  confirmed: ['ok', 'CONFIRMED', 'Confirmed live: sent to real glasses and seen working (docs/status.md)'],
  ack: ['ack', 'ACK-CONFIRMED', 'Acknowledged by the glasses on every send; how it looks on the glass is still on the visual checklist (docs/status.md)'],
  exp: ['exp', 'EXPERIMENTAL', 'Not yet confirmed on real glasses (docs/status.md)'],
  hub: ['hub', 'HUB-SIDE', 'Runs on this computer; nothing new is sent to the glasses'],
};
function badge(kind) {
  const [cls, label, tip] = STATUS[kind];
  return `<span class="badge ${cls}" title="${escapeHtml(tip)}">${label}</span>`;
}
function tileHtml(p) {
  const [sec, id, title, blurb, ico, beta] = p;
  return `<button type="button" class="tile" data-go="${sec}/${id}" data-tile="${id}">`
    + `<span class="tIco">${svgIco(ico)}</span><span class="tTxt"><b>${escapeHtml(title)}${beta ? ' <span class="badge exp plain">Beta</span>' : ''}</b>`
    + `<span class="tSub" data-tile-sub="${id}">${escapeHtml(blurb)}</span></span><span class="chev" aria-hidden="true"></span></button>`;
}
// Live one-liners on the app tiles (e.g. "Listening now"); '' restores the description.
function tileState(id, text) {
  const p = PAGES.find(x => x[1] === id);
  document.querySelectorAll(`[data-tile-sub="${id}"]`).forEach(el => {
    el.textContent = text || (p ? p[3] : '');
    el.closest('.tile').classList.toggle('live', !!text);
  });
}
function decorateCard(c) {
  const h2 = c.querySelector('h2');
  const st = c.dataset.status;
  if (h2 && !h2.classList.contains('sr-only')) {
    if (c.dataset.icon && ICO[c.dataset.icon]) h2.insertAdjacentHTML('afterbegin', `<span class="cIco">${svgIco(c.dataset.icon)}</span>`);
    const title = h2.querySelector('.cIco') ? h2.childNodes[1] : h2.firstChild;
    const extra = document.createElement('span');
    extra.className = 'hBadges';
    if (st === 'exp' && !h2.querySelector('.badge')) extra.innerHTML = '<span class="badge exp plain beta-pill">Beta</span>';
    if (st && STATUS[st]) extra.insertAdjacentHTML('beforeend', badge(st).replace('class="badge ', 'class="dev-only badge '));
    if (extra.innerHTML) h2.insertBefore(extra, title ? title.nextSibling : null);
  }
  if (c.hasAttribute('data-beta')) c.classList.add('beta-only');
}
function buildShell() {
  const nav = $('nav'), host = $('sections');
  document.querySelectorAll('[data-ico]').forEach(el => { el.innerHTML = svgIco(el.dataset.ico); });
  const cards = Array.from(document.querySelectorAll('#cards > .card'));
  cards.forEach(decorateCard);
  let devHeader = false;
  for (const [id, label, ico, intro, group] of SECTIONS) {
    const sec = document.createElement('div');
    sec.className = 'section' + (id === 'log' ? ' single' : '') + (group === 'dev' ? ' tools dev-only' : '');
    sec.id = 'sec-' + id;
    sec.setAttribute('role', 'region');
    sec.setAttribute('aria-label', label);
    const legend = id === 'developer' ? `<span class="legend">Evidence: ${badge('confirmed')} ${badge('ack')} ${badge('exp')} ${badge('hub')}</span>` : '';
    if (intro) sec.innerHTML = `<p class="section-intro">${intro}${legend}</p>`;
    const pick = cards.filter(c => c.dataset.sec === id && !c.dataset.page);
    pick.filter(c => c.dataset.col === 'top').forEach(c => { c.classList.add('full'); sec.appendChild(c); });
    const cols = id === 'log' ? [document.createElement('div')] : [document.createElement('div'), document.createElement('div')];
    const pages = PAGES.filter(p => p[0] === id);
    if (pages.length) {
      const g = document.createElement('div');
      g.className = 'tileGrid full';
      g.innerHTML = pages.map(tileHtml).join('');
      sec.appendChild(g);
    }
    const colCards = pick.filter(c => c.dataset.col === '0' || c.dataset.col === '1');
    if (colCards.length) {
      cols.forEach(c => { c.className = 'col'; sec.appendChild(c); });
      colCards.forEach(c => cols[Math.min(cols.length - 1, parseInt(c.dataset.col))].appendChild(c));
    }
    pick.filter(c => c.dataset.col === 'full').forEach(c => { c.classList.add('full'); sec.appendChild(c); });
    host.appendChild(sec);
    for (const p of pages) {
      const pg = document.createElement('div');
      pg.className = 'section page';
      pg.id = `sec-${id}-${p[1]}`;
      pg.setAttribute('role', 'region');
      pg.setAttribute('aria-label', p[2]);
      cards.filter(c => c.dataset.sec === id && c.dataset.page === p[1]).forEach(c => pg.appendChild(c));
      host.appendChild(pg);
    }
    if (group === 'dev' && !devHeader) {
      devHeader = true;
      const g = document.createElement('div');
      g.className = 'nav-group dev-only'; g.textContent = 'Developer';
      nav.appendChild(g);
    }
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'nav-btn' + (group === 'dev' ? ' tool dev-only' : ''); b.dataset.sec = id;
    b.innerHTML = `<span class="ico" aria-hidden="true">${svgIco(ico)}</span><span class="lbl">${label}</span>`;
    b.addEventListener('click', () => { if (b.offsetParent !== null) go(id, {push: true, focus: true}); });   // hidden = Developer mode off (desktop Ctrl+6/7)
    nav.appendChild(b);
  }
  $('homeApps').innerHTML = PAGES.map(tileHtml).join('');
  $('backBtn').addEventListener('click', () => go(route.split('/')[0], {push: true, focus: true}));
}
let route = '';
// Show a section ('apps') or a sub-page ('apps/translate'). opts.push: add a history entry.
function go(r, opts) {
  opts = opts || {};
  r = String(r || '').replace(/^#/, '');
  r = ALIASES[r] || r;
  let [sec, page] = r.split('/');
  const def = SECTIONS.find(s => s[0] === sec);
  if (!def || (def[4] === 'dev' && !devOn())) { sec = 'home'; page = ''; }
  if (page && !$(`sec-${sec}-${page}`)) page = '';
  const id = page ? `sec-${sec}-${page}` : 'sec-' + sec;
  const next = page ? sec + '/' + page : sec;
  const changed = next !== route;
  document.querySelectorAll('.section').forEach(s => s.classList.toggle('active', s.id === id));
  document.querySelectorAll('.nav-btn').forEach(b => {
    const on = b.dataset.sec === sec;
    b.classList.toggle('active', on);
    if (on) b.setAttribute('aria-current', 'page'); else b.removeAttribute('aria-current');
  });
  const secDef = SECTIONS.find(s => s[0] === sec), pageDef = page && PAGES.find(p => p[0] === sec && p[1] === page);
  $('pageTitle').textContent = pageDef ? pageDef[2] : secDef[1];
  $('backBtn').hidden = !pageDef;
  $('backLbl').textContent = secDef[1];
  document.body.dataset.route = sec;
  route = next;
  try { localStorage.setItem('g2hub.section', next); } catch (e) {}
  try {
    if (opts.push && changed) history.pushState(null, '', '#' + next);
    else history.replaceState(null, '', '#' + next);
  } catch (e) {}
  if (changed) $('main').scrollTop = 0;
  if (opts.focus) { try { $('pageTitle').focus({preventScroll: true}); } catch (e) {} }
  if (sec === 'log') logEl.scrollTop = logEl.scrollHeight;
  if (sec === 'apps') ehLoad();
}
function showSection(id) { go(id, {push: true}); }      // older name, kept for callers
window.addEventListener('popstate', () => go(location.hash));
window.addEventListener('hashchange', () => { if (location.hash.slice(1) !== route) go(location.hash); });
document.addEventListener('click', (e) => {
  const t = e.target.closest('[data-go]');
  if (!t || t.disabled) return;
  e.preventDefault();
  go(t.dataset.go, {push: true, focus: true});
});

// Beta features (Stocks, Health, Watchface) and Developer mode (Developer + Log sections, evidence
// badges, technical details) are per-browser switches in Settings. Older pages had one "Labs"
// switch that showed the Developer tab: someone who had it on keeps Developer mode on.
function lsGet(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }
function lsSet(k, v) { try { if (v === null) localStorage.removeItem(k); else localStorage.setItem(k, v); } catch (e) {} }
if (lsGet('g2hub.ui') !== '2') { if (lsGet('g2hub.labs') === '1' && lsGet('g2hub.dev') === null) lsSet('g2hub.dev', '1'); lsSet('g2hub.ui', '2'); }
function labsOn() { return lsGet('g2hub.labs') === '1'; }
function devOn() { return lsGet('g2hub.dev') === '1'; }
function labsApply() {
  const root = document.documentElement;
  root.classList.toggle('beta-mode', labsOn());
  root.classList.toggle('dev-mode', devOn());
  if ($('labsToggle')) $('labsToggle').checked = labsOn();
  if ($('devToggle')) $('devToggle').checked = devOn();
  const def = SECTIONS.find(s => s[0] === route.split('/')[0]);
  if (def && def[4] === 'dev' && !devOn()) go('settings');
}
function labsSet(on) {
  lsSet('g2hub.labs', on ? '1' : null);
  labsApply();
  toast(on ? 'Beta features shown' : 'Beta features hidden', 'ok');
}
function devSet(on) {
  lsSet('g2hub.dev', on ? '1' : '0');
  labsApply();
  toast(on ? 'Developer mode on: Developer and Log are in the menu' : 'Developer mode off', 'ok');
}
buildShell();
labsApply();
{
  let start = (location.hash || '').slice(1);
  const ok = (r) => { r = ALIASES[r] || r; const [s, p] = r.split('/'); return !!$('sec-' + s) && (!p || !!$(`sec-${s}-${p}`)); };
  if (!ok(start)) start = lsGet('g2hub.section') || '';
  go(ok(start) ? start : 'home');
}

/* colour theme: '' = Even following the system light/dark (default), 'even-light', 'even-dark',
   'green' = Phosphor Green, 'amber' = Amber CRT. The <head> script applies the saved one on load. */
const THEMES = ['even-light', 'even-dark', 'green', 'amber'];
function themeSet(v) {
  if (THEMES.includes(v)) document.documentElement.dataset.theme = v; else delete document.documentElement.dataset.theme;
  try { if (THEMES.includes(v)) localStorage.setItem('g2hub.theme', v); else localStorage.removeItem('g2hub.theme'); } catch (e) {}
}
$('themeSel').value = document.documentElement.dataset.theme || '';
$('hubAddr').textContent = location.host + (conn.version ? ' · v' + conn.version : '');

// ───────────────────────── Home: quick controls + summary ─────────────────────────
// Toggle tiles post one setting at a time (POST /api/settings only changes the keys it is given)
// and read their state from the live glasses status, else from what is saved for this pair.
const TGL = {   // key -> [label, live status key, saved settings key]
  silent_mode: ['Silent mode', 'silent_mode', 'silent_mode'],
  auto_brightness: ['Auto brightness', 'brightness_auto', 'auto_brightness'],
  head_up: ['Head-up dashboard', 'head_up', 'head_up'],
};
let ltCur = {};
function tglValue(k) {
  if (k === 'live_translate') return !!ltCur.on;
  const [, sk, vk] = TGL[k];
  const s = conn.status || {}, saved = (settingsData && settingsData.saved) || {};
  if (conn.connected && s[sk] !== undefined) return !!s[sk];
  return !!saved[vk];
}
function tglRender() {
  document.querySelectorAll('.tgl').forEach(b => {
    const k = b.dataset.tgl, on = tglValue(k);
    b.setAttribute('aria-pressed', on ? 'true' : 'false');
    b.classList.toggle('on', on);
    let sub = on ? 'On' : 'Off';
    if (k === 'live_translate' && on) sub = 'On · ' + (ltCur.src || '?') + ' → ' + (ltCur.dst || '?');
    b.querySelector('.tSub').textContent = sub;
  });
  const qb = $('qBright');
  if (qb && document.activeElement !== qb) {
    const saved = (settingsData && settingsData.saved) || {};
    if (settingsData && settingsData.brightness_range) { qb.min = settingsData.brightness_range[0]; qb.max = settingsData.brightness_range[1]; }
    if (saved.brightness !== undefined) qb.value = saved.brightness;
    $('qBrightVal').textContent = tglValue('auto_brightness') ? 'Auto' : qb.value;
  }
}
function settingsSaved(saved) {   // keep the Display card and the Home tiles in step after a quick change
  if (!saved) return;
  settingsData = settingsData || {};
  settingsData.saved = saved;
  if (saved.silent_mode !== undefined) $('setSilent').checked = !!saved.silent_mode;
  if (saved.auto_brightness !== undefined) $('setAuto').checked = !!saved.auto_brightness;
  if (saved.head_up !== undefined) $('setHeadUp').checked = !!saved.head_up;
  if (saved.brightness !== undefined) { $('setBright').value = saved.brightness; $('setBrightVal').textContent = saved.brightness; }
  const st = conn.status || {};       // the glasses send a fresh read-back; show the change meanwhile
  if (saved.silent_mode !== undefined) st.silent_mode = saved.silent_mode ? 1 : 0;
  if (saved.auto_brightness !== undefined) st.brightness_auto = saved.auto_brightness ? 1 : 0;
  if (saved.head_up !== undefined) st.head_up = saved.head_up ? 1 : 0;
  tglRender();
}
$('tglGrid').addEventListener('click', async (e) => {
  const b = e.target.closest('.tgl');
  if (!b || b.disabled || b.dataset.busy === '1') return;
  const k = b.dataset.tgl, next = !tglValue(k);
  if (k === 'live_translate') {
    const body = {on: next};
    if (val('ltSrc')) { body.src = val('ltSrc'); body.dst = val('ltDst'); }
    setBusy(b, true);
    try { await ltPost(body); } finally { setBusy(b, false); tglRender(); }
    return;
  }
  const label = TGL[k][0];
  const d = await call(b, '/api/settings', {[k]: next}, `${label} ${next ? 'on' : 'off'}`, {what: label});
  if (d) settingsSaved(d.saved);
  tglRender();
});
$('qBright').addEventListener('input', () => { $('qBrightVal').textContent = $('qBright').value; });
$('qBright').addEventListener('change', async () => {
  const v = parseInt(val('qBright'));
  const d = await call(null, '/api/settings', {auto_brightness: false, brightness: v}, '', {what: 'Brightness'});
  if (d) settingsSaved(d.saved); else tglRender();
});
// "On your glasses" rows on Home (filled by the widget loaders).
function homeSum(id, text) { const el = $(id); if (el) el.textContent = text; }

// ───────────────────────── live log ─────────────────────────
const LOG_MAX = 1500;
const LEVEL_RANK = {info: 0, ok: 1, warn: 2, err: 3};
const logState = {paused: false, buffer: []};
function logMatches(row) {
  const lv = val('logLevel'), q = val('logFilter').trim().toLowerCase();
  const l = row.dataset.level;
  if (lv === 'ok' && l !== 'ok') return false;
  if (lv === 'warn' && LEVEL_RANK[l] < 2) return false;
  if (lv === 'err' && l !== 'err') return false;
  return !q || row.textContent.toLowerCase().includes(q);
}
function logCount() {
  const rows = logEl.children.length, shown = logEl.querySelectorAll('.logRow:not(.hide)').length;
  $('logCount').textContent = (shown === rows ? `${rows} lines` : `${shown} of ${rows} lines`)
    + (logState.paused ? ` · paused, ${logState.buffer.length} new` : '');
}
function renderRow(ev) {
  const div = document.createElement('div');
  const lvl = LEVEL_RANK[ev.level] !== undefined ? ev.level : 'info';
  div.className = 'logRow';
  div.dataset.level = lvl;
  const t = (ev.ts ? new Date(ev.ts * 1000) : new Date()).toLocaleTimeString();   // replayed history keeps its own time
  div.innerHTML = `<span class="t">[${t}]</span> <span class="lvl-${lvl}">${escapeHtml(ev.message || ev.type || '')}</span>`;
  if (!logMatches(div)) div.classList.add('hide');
  const atBottom = logEl.scrollHeight - logEl.scrollTop - logEl.clientHeight < 40;
  logEl.appendChild(div);
  while (logEl.children.length > LOG_MAX) logEl.firstChild.remove();
  if ($('logFollow').checked && atBottom) logEl.scrollTop = logEl.scrollHeight;
}
function addRow(ev) {
  if (logState.paused) { logState.buffer.push(ev); if (logState.buffer.length > LOG_MAX) logState.buffer.shift(); }
  else renderRow(ev);
  logCount();
}
function logRefilter() {
  logEl.querySelectorAll('.logRow').forEach(r => r.classList.toggle('hide', !logMatches(r)));
  logCount();
}
function logTogglePause() {
  logState.paused = !logState.paused;
  const b = $('logPauseBtn');
  b.textContent = logState.paused ? 'Resume' : 'Pause';
  b.setAttribute('aria-pressed', logState.paused ? 'true' : 'false');
  if (!logState.paused) {
    const buf = logState.buffer; logState.buffer = [];
    buf.forEach(renderRow);
    if ($('logFollow').checked) logEl.scrollTop = logEl.scrollHeight;
  }
  logCount();
}
function logClear() { logEl.innerHTML = ''; logState.buffer = []; logCount(); }

// ───────────────────────── websocket ─────────────────────────
let wsWasOpen = false;
function connect() {
  const ws = new WebSocket(`${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws`);
  ws.onopen = () => {
    // The hub replays its recent history to every new socket: start the view afresh so a
    // reconnect does not duplicate it, and reload everything if the hub restarted meanwhile.
    logEl.innerHTML = ''; logState.buffer = [];
    if (wsWasOpen || !conn.hub) loadAll();
    wsWasOpen = true;
    conn.hub = true; statusLoad();
  };
  ws.onmessage = (msg) => {
    let ev;
    try { ev = JSON.parse(msg.data); } catch (e) { return; }
    if (ev.type === 'state') {
      if (ev.key === 'even_ai_log') aiLoadHistory();
      else if (ev.key === 'devices') devLoad();
      else if (ev.key === 'translate_live') ltLoad();
      else if (ev.key === 'all') loadAll();
      else loadHubState();
      return;
    }
    if (ev.type === 'connection') {
      conn.connected = !!ev.connected;
      renderConn(); devLoad(); statusLoad();
    }
    if (ev.type === 'ai') { aiSetPhase(ev); return; }
    if (ev.type === 'glasses_status') { showGlassStatus(ev.status); return; }
    if (ev.type === 'connection') ev = {level: ev.connected ? 'ok' : 'warn', message: ev.connected ? 'Glasses connected' : 'Glasses disconnected', ts: ev.ts};
    addRow(ev);
  };
  ws.onclose = () => {
    if (conn.hub) { conn.hub = false; renderConn(); }
    setTimeout(connect, 2000);
  };
}

// ───────────────────────── calendar ─────────────────────────
const CAL_DURATIONS = [[15, '15 min'], [30, '30 min'], [45, '45 min'], [60, '1 h'], [90, '1.5 h'], [120, '2 h'], [180, '3 h'], [0, 'All day']];
let calDebounce = null, qlDebounce = null, menuDebounce = null;
let ehMenuCount = 0;   // EvenHub apps in this pair's menu (set by ehLoad)
function pad2(n) { return String(n).padStart(2, '0'); }
function editing(listId, timer) {
  const a = document.activeElement;
  return !!timer || !!(a && a.closest && a.closest('#' + listId));
}
function calEmptyState() {
  const list = $('calEvents');
  const empty = list.querySelector('.empty');
  const rows = list.querySelectorAll('.calRow').length;
  if (!rows && !empty) list.insertAdjacentHTML('afterbegin', '<div class="empty">No events yet. Add one below, or sync a calendar.</div>');
  if (rows && empty) empty.remove();
}
function calAdd(ev) {
  const start = ev.start ? new Date(ev.start * 1000)
    : new Date(Math.ceil((Date.now() + (ev.minutesFromNow ?? 60) * 60000) / 300000) * 300000);
  const dur = ev.all_day ? 0 : ev.end && ev.start ? Math.round((ev.end - ev.start) / 60) : 60;
  const row = document.createElement('div');
  row.className = 'itemRow calRow';
  const opts = CAL_DURATIONS.map(([m, l]) => `<option value="${m}" ${m === dur ? 'selected' : ''}>${l}</option>`).join('')
    + (CAL_DURATIONS.some(([m]) => m === dur) ? '' : `<option value="${Number(dur)}" selected>${Number(dur)} min</option>`);
  row.innerHTML = `
    <input type="text" class="calT" placeholder="Title" aria-label="Event title" value="${escapeHtml(ev.title || '')}">
    <input type="text" class="calL" placeholder="Location" aria-label="Location" value="${escapeHtml(ev.location || '')}">
    <input type="date" class="calD" aria-label="Date" value="${start.getFullYear()}-${pad2(start.getMonth() + 1)}-${pad2(start.getDate())}">
    <input type="time" class="calS" aria-label="Start time" value="${pad2(start.getHours())}:${pad2(start.getMinutes())}">
    <select class="calDur" aria-label="Duration">${opts}</select>
    <button type="button" class="icon" aria-label="Remove event" title="Remove">✕</button>`;
  row.querySelector('button').addEventListener('click', () => { row.remove(); calEmptyState(); scheduleCalPush(); });
  row.querySelectorAll('input,select').forEach(el => el.addEventListener('input', scheduleCalPush));
  $('calEvents').appendChild(row);
  calEmptyState();
  if (!ev.title && !ev.start) row.querySelector('.calT').focus();
}
function collectCalendar() {
  return Array.from(document.querySelectorAll('#calEvents .calRow')).map(r => {
    const title = r.querySelector('.calT').value.trim();
    const [y, mo, d] = r.querySelector('.calD').value.split('-').map(Number);
    const [h, mi] = (r.querySelector('.calS').value || '09:00').split(':').map(Number);
    const dur = parseInt(r.querySelector('.calDur').value);
    const allDay = dur === 0;
    const start = allDay ? new Date(y, mo - 1, d, 0, 0) : new Date(y, mo - 1, d, h, mi);
    const end = allDay ? new Date(y, mo - 1, d, 23, 59) : new Date(start.getTime() + dur * 60000);
    return {title, location: r.querySelector('.calL').value.trim(), start: Math.floor(start / 1000),
            end: Math.floor(end / 1000), all_day: allDay};
  }).filter(e => e.title && !isNaN(e.start));
}
function calSyncedRow(ev) {
  const when = ev.all_day ? new Date(ev.start * 1000).toLocaleDateString([], {weekday: 'short', month: 'short', day: 'numeric'}) + ' · all day'
    : new Date(ev.start * 1000).toLocaleString([], {weekday: 'short', hour: 'numeric', minute: '2-digit'});
  return `<div class="itemRow calSyncedRow"><span class="calTag">synced</span><span class="calSTitle">${escapeHtml(ev.title)}</span>`
    + `<span class="calSMeta">${escapeHtml(when)}${ev.location ? ' · ' + escapeHtml(ev.location) : ''}</span></div>`;
}
function renderCalSync(s) {
  s = s || {};
  const url = $('calIcsUrl');
  if (document.activeElement !== url) url.value = s.url || '';
  $('calIcsOn').checked = !!s.enabled;
  const ago = t => t ? new Date(t * 1000).toLocaleTimeString([], {hour: 'numeric', minute: '2-digit'}) : '';
  let line = 'Not synced.';
  if (s.enabled && s.note) line = `Sync problem: ${s.note}` + (s.last_ok ? ` (last good sync ${ago(s.last_ok)})` : '');
  else if (s.enabled && s.last_ok) line = `Last synced ${ago(s.last_ok)}, ${s.count} event(s) in the next few days.`;
  else if (s.enabled) line = 'Waiting for the first sync…';
  else if (s.url) line = 'Paused (sync is off).';
  $('calSyncLine').textContent = line;
}
async function calSyncSave(now) {
  const url = $('calIcsUrl').value.trim();
  setSyncState('calSync', 'pending', '● syncing…');
  const body = {url, enabled: now ? !!url : $('calIcsOn').checked};
  const d = await postJson('/api/calendar/sync', body);
  if (d.error) { setSyncState('calSync', 'error', '✕ ' + d.error); toast('Calendar: ' + d.error, 'err'); return; }
  renderCalendar(d);
  const bad = d.sync && d.sync.enabled && d.sync.note;
  setSyncState('calSync', bad ? 'error' : 'synced', bad ? '✕ sync failed' : (d.note ? '● saved (glasses offline)' : `✓ ${d.sent} on glasses`));
}
function renderCalendar(c) {
  const list = $('calEvents');
  list.innerHTML = '';
  const evs = c.events || [];
  evs.filter(e => e.source !== 'ics').forEach(calAdd);
  $('calSynced').innerHTML = evs.filter(e => e.source === 'ics').map(calSyncedRow).join('');
  renderCalSync(c.sync);
  calEmptyState();
  $('calH24').checked = !!c.h24;
  const next = (c.events || []).filter(e => e.end * 1000 > Date.now());
  const calEl = $('calState');
  calEl.hidden = !next.length;
  const when = next.length ? new Date(next[0].start * 1000).toLocaleString([], {weekday: 'short', hour: 'numeric', minute: '2-digit'}) : '';
  calEl.innerHTML = next.length ? `<span class="k">Next</span> ${escapeHtml(next[0].title)} · ${escapeHtml(when)}` : '';
  homeSum('hsCal', next.length ? `${next[0].title} · ${when}` : 'Nothing coming up');
}
async function calLoad(force) {
  if (!force && editing('calEvents', calDebounce)) return;
  try { renderCalendar(await getJson('/api/calendar')); } catch (e) {}
}
function scheduleCalPush() {
  setSyncState('calSync', 'pending', '● saving…');
  clearTimeout(calDebounce);
  calDebounce = setTimeout(async () => {
    calDebounce = null;
    const d = await postJson('/api/calendar', {events: collectCalendar(), h24: $('calH24').checked});
    if (d.error) { setSyncState('calSync', 'error', '✕ ' + d.error); toast('Calendar: ' + d.error, 'err'); return; }
    setSyncState('calSync', 'synced', d.note ? '● saved (glasses offline)' : `✓ ${d.sent} on glasses`);
  }, 1500);
}

// ───────────────────────── tasks ─────────────────────────
function collectTasks() {
  return Array.from(document.querySelectorAll('#qlItemsList .itemRow')).map(r => ({
    uid: r.dataset.uid ? parseInt(r.dataset.uid) : undefined,
    title: r.querySelector('input[type=text]').value.trim(),
    completed: r.querySelector('input[type=checkbox]').checked,
  })).filter(t => t.title);
}
function qlEmptyState() {
  const list = $('qlItemsList');
  const empty = list.querySelector('.empty');
  const rows = list.querySelectorAll('.itemRow').length;
  if (!rows && !empty) list.insertAdjacentHTML('afterbegin', '<div class="empty">No tasks yet. Add one below.</div>');
  if (rows && empty) empty.remove();
}
function addQuicklistRow(text, autoSync, completed, uid) {
  const list = $('qlItemsList');
  const row = document.createElement('div');
  row.className = 'itemRow';
  if (uid) row.dataset.uid = Number(uid);
  row.innerHTML = `
    <input type="checkbox" aria-label="Done" title="Done" ${completed ? 'checked' : ''}>
    <input type="text" placeholder="Task text" aria-label="Task" value="${text ? escapeHtml(text) : ''}" class="${completed ? 'done' : ''}">
    <button type="button" class="icon" aria-label="Remove task" title="Remove">✕</button>`;
  const chk = row.querySelector('input[type=checkbox]'), txt = row.querySelector('input[type=text]');
  chk.addEventListener('change', () => { txt.classList.toggle('done', chk.checked); scheduleQlPush(); });
  txt.addEventListener('input', scheduleQlPush);
  row.querySelector('button').addEventListener('click', () => { row.remove(); qlEmptyState(); scheduleQlPush(); });
  list.appendChild(row);
  qlEmptyState();
  if (autoSync) scheduleQlPush();
  if (!text && !autoSync) txt.focus();
}
function scheduleQlPush() {
  clearTimeout(qlDebounce);
  if (!conn.connected) { qlDebounce = null; setSyncState('qlSync', 'error', '● offline: not sent'); return; }
  setSyncState('qlSync', 'pending', '● syncing…');
  qlDebounce = setTimeout(async () => {
    qlDebounce = null;
    const items = collectTasks();
    if (!items.length) { setSyncState('qlSync', 'idle', '● empty list is not sent'); return; }
    const d = await postJson('/api/push_quicklist', {items});
    if (d.error) { setSyncState('qlSync', 'error', '✕ ' + d.error); toast('Tasks: ' + d.error, 'err'); return; }
    setSyncState('qlSync', 'synced', '✓ synced');
    setTimeout(loadHubState, 500);
  }, 1200);
}

// ───────────────────────── menu ─────────────────────────
const DEFAULT_MENU = [7, 6, 5, 8, 1];
function appLabel(id) { const o = MENU_APPS.find(([, v]) => v === id); return o ? o[0] : String(id); }
// Built-in menu items are just app IDs (the glasses draw name + icon). 5-10 items, no duplicates.
function collectMenu() {
  const rows = Array.from(document.querySelectorAll('#menuItemsList .itemRow'));
  const seen = new Set();
  let error = '';
  const items = rows.map(r => {
    const sel = r.querySelector('select');
    const appId = parseInt(sel.value);
    const dup = seen.has(appId);
    sel.style.borderColor = dup ? 'var(--red)' : '';
    if (dup) error = error || `${appLabel(appId)} is in the menu twice.`;
    seen.add(appId);
    return {appId};
  });
  const total = items.length + ehMenuCount;
  if (!error && (total < 5 || total > 10))
    error = `The glasses need 5–10 menu items (you have ${items.length}` + (ehMenuCount ? ` + ${ehMenuCount} EvenHub` : '') + ').';
  const errEl = $('menuErr');
  errEl.textContent = error;
  errEl.hidden = !error;
  return error ? {error} : {items};
}
async function sendMenu(items, btn) {
  setSyncState('menuSync', 'pending', '● sending…');
  const d = await call(btn, '/api/push_menu', {items}, btn ? 'Menu replaced on the glasses' : '', {what: 'Menu'});
  if (d) setSyncState('menuSync', 'synced', '✓ synced');
  else setSyncState('menuSync', 'error', '✕ not sent');
}
function scheduleMenuPush() {
  clearTimeout(menuDebounce);
  const m = collectMenu();
  if (m.error) { menuDebounce = null; setSyncState('menuSync', 'error', '✕ fix the menu'); return; }
  if (!conn.connected) { menuDebounce = null; setSyncState('menuSync', 'error', '● offline: not sent'); return; }
  setSyncState('menuSync', 'pending', '● syncing…');
  menuDebounce = setTimeout(() => {
    menuDebounce = null;
    const m2 = collectMenu();
    if (m2.error) { setSyncState('menuSync', 'error', '✕ fix the menu'); return; }
    sendMenu(m2.items);
  }, 2000);
}
function addMenuRow(appId, autoSync) {
  const list = $('menuItemsList');
  if (appId == null) {
    const used = new Set(Array.from(list.querySelectorAll('select')).map(s => parseInt(s.value)));
    const free = MENU_APPS.find(([, id]) => !used.has(id));
    if (!free) { toast('Every built-in app is already in the menu.', 'warn'); return; }
    appId = free[1];
  }
  const row = document.createElement('div');
  row.className = 'itemRow';
  const options = MENU_APPS.map(([label, id]) =>
    `<option value="${Number(id)}" ${id === appId ? 'selected' : ''}>${escapeHtml(label)}</option>`).join('');
  row.innerHTML = `<select aria-label="Menu item">${options}</select>
    <button type="button" class="icon" aria-label="Remove menu item" title="Remove">✕</button>`;
  row.querySelector('select').addEventListener('change', scheduleMenuPush);
  row.querySelector('button').addEventListener('click', () => { row.remove(); scheduleMenuPush(); });
  list.appendChild(row);
  if (autoSync) scheduleMenuPush();
}
function renderMenu(appIds) {
  $('menuItemsList').innerHTML = '';
  appIds.forEach(id => addMenuRow(id, false));
  collectMenu();
}

// ── hub state mirror (what was last pushed) ──
async function loadHubState() {
  calLoad();
  let s = {};
  try { s = await getJson('/api/hub_state'); } catch (e) { s = null; }
  if (s === null) {
    if (!document.querySelector('#menuItemsList .itemRow')) renderMenu(DEFAULT_MENU);
    qlEmptyState();
    return;
  }
  // Tasks (not while the user is typing in the list or a push is pending)
  if (!editing('qlItemsList', qlDebounce)) {
    const qlEl = $('qlState');
    const list = $('qlItemsList');
    const q = s.quicklist || {};
    list.innerHTML = '';
    if (q.items && q.items.length) {
      const preview = q.items.slice(0, 3).join(' · ') + (q.items.length > 3 ? ` +${q.items.length - 3}` : '');
      qlEl.innerHTML = `<span class="k">On your glasses</span> ${escapeHtml(preview)} · ${escapeHtml(fmtAgo(q.pushed_ago_min))}`;
      qlEl.hidden = false;
      (q.tasks || q.items.map(t => ({title: t, completed: false})))
        .forEach(t => addQuicklistRow(t.title, false, t.completed, t.uid));
      setSyncState('qlSync', 'synced', q.source === 'glasses' ? '✓ synced from glasses' : '✓ synced');
    } else {
      qlEl.hidden = true;
      if (q.source === 'glasses') setSyncState('qlSync', 'synced', '✓ synced from glasses');
    }
    qlEmptyState();
    const ts = (q.tasks || (q.items || []).map(t => ({completed: false})));
    const open = ts.filter(t => !t.completed).length;
    homeSum('hsTasks', ts.length ? `${open} open${ts.length - open ? ' · ' + (ts.length - open) + ' done' : ''}` : 'No tasks');
  }
  // Menu
  if (!editing('menuItemsList', menuDebounce)) {
    if (s.menu && s.menu.items && s.menu.items.length) {
      renderMenu(s.menu.items.map(i => i.appId));
      setSyncState('menuSync', 'synced', '✓ synced');
    } else if (!document.querySelector('#menuItemsList .itemRow')) {
      renderMenu(DEFAULT_MENU);
      setSyncState('menuSync', 'idle', '● default (not sent yet)');
    }
  }
}

// ── manual pushes (Developer) ──
function pushCalendar(btn) {
  call(btn, '/api/calendar', {events: collectCalendar(), h24: $('calH24').checked},
       d => d.note ? 'Calendar saved (glasses offline)' : `Calendar pushed: ${d.sent ?? 0} event(s) on the glasses`, {what: 'Calendar'})
    .then(d => { if (d) setSyncState('calSync', 'synced', d.note ? '● saved (glasses offline)' : `✓ ${d.sent ?? 0} on glasses`); });
}
function pushQuicklist(btn) {
  const items = collectTasks();
  if (!items.length) { toast('Add at least one task in Dashboard → Tasks first.', 'warn'); return; }
  call(btn, '/api/push_quicklist', {items}, `Tasks pushed (${items.length})`, {what: 'Tasks'})
    .then(d => { if (d) { setSyncState('qlSync', 'synced', '✓ synced'); setTimeout(loadHubState, 500); } });
}
async function pushMenuForce(btn) {
  const m = collectMenu();
  if (m.error) { toast(m.error, 'warn'); return; }
  if (!await uiConfirm('Replace the menu on the glasses with ' + m.items.length + ' built-in item(s)' + (ehMenuCount ? ` + ${ehMenuCount} EvenHub` : '') + '?', {ok: 'Replace menu', danger: true})) return;
  sendMenu(m.items, btn);
}

// ───────────────────────── news ─────────────────────────
async function refreshHNStatus() {
  try {
    const d = await getJson('/api/news_status');
    const ageEl = $('hnStatusAge'), pushedEl = $('hnStatusPushed');
    if (!d.cached) {
      ageEl.textContent = 'no stories fetched yet';
      pushedEl.textContent = '';
      homeSum('hsNews', 'No stories yet');
    } else {
      ageEl.textContent = `updated ${fmtAgo(d.age_min)} · ${d.story_count} stories`;
      const sent = d.pushed_min !== null && d.pushed_min !== undefined;
      pushedEl.textContent = sent ? `· sent ${fmtAgo(d.pushed_min)}` : '· not sent yet';
      homeSum('hsNews', `${d.story_count} stories · updated ${fmtAgo(d.age_min)}`);
    }
  } catch (e) {}
}
async function autoPushNow(btn) {
  const d = await call(btn, '/api/auto_push_hn', {}, conn.connected ? 'Fetching fresh stories for your glasses…'
                                                                     : 'Fetching fresh stories; they are sent when your glasses connect', {what: 'News'});
  if (d) { setSyncState('feedSync', 'pending', '● refreshing…'); setTimeout(() => { refreshHNStatus(); setSyncState('feedSync', 'idle', '● idle'); }, 8000); }
}
let hnStories = [];
function storyHost(u) { try { return new URL(u).hostname.replace(/^www[.]/, ''); } catch (e) { return ''; } }
async function fetchHN(btn) {
  const storiesDiv = $('hnStories');
  setBusy(btn, true);
  storiesDiv.innerHTML = '<div class="skel"></div><div class="skel"></div><div class="skel"></div>';
  $('hnActions').hidden = true;
  try {
    const data = await getJson('/api/fetch_hacker_news');
    if (data.error) throw new Error(data.error);
    hnStories = data.stories || [];
    renderHNStories();
    $('hnActions').hidden = !hnStories.length;
    refreshHNStatus();
  } catch (e) {
    storiesDiv.innerHTML = `<div class="hnLoading bad-t">Could not fetch stories: ${escapeHtml(e.message)}</div>`;
  } finally {
    setBusy(btn, false);
  }
}
function renderHNStories() {
  const div = $('hnStories');
  if (!hnStories.length) { div.innerHTML = '<div class="empty">No stories found. Try other sources.</div>'; return; }
  div.innerHTML = hnStories.map((s, i) => {
    const host = storyHost(s.url);
    const link = /^https?:/.test(s.url || '') ? ` · <a href="${escapeHtml(s.url)}" target="_blank" rel="noopener noreferrer">${escapeHtml(host || 'open')}</a>` : '';
    return `<div class="hnStory sel" data-i="${i}">
      <input type="checkbox" checked aria-label="Send this story">
      <div>
        <div class="hnTitle">${escapeHtml(s.title)}</div>
        <div class="hnMeta">${escapeHtml(s.source || 'News')}${link}${s.text_extracted ? '' : ' · summary only'}</div>
      </div>
    </div>`;
  }).join('');
}
$('hnStories').addEventListener('click', (e) => {
  if (e.target.closest('a')) return;
  const card = e.target.closest('.hnStory');
  if (!card) return;
  const chk = card.querySelector('input[type=checkbox]');
  if (e.target !== chk) chk.checked = !chk.checked;
  card.classList.toggle('sel', chk.checked);
});
function pushHNNews(btn) {
  const selected = hnStories.filter((_, i) => { const c = document.querySelector(`.hnStory[data-i="${i}"] input`); return c && c.checked; });
  if (!selected.length) { toast('Select at least one story.', 'warn'); return; }
  const articles = selected.map(s => ({title: s.title, source: s.source || 'News', content: s.content || s.url || s.title}));
  call(btn, '/api/push_news', {articles}, `Sent ${articles.length} stor${articles.length === 1 ? 'y' : 'ies'} to the glasses`, {what: 'News'})
    .then(() => refreshHNStatus());
}
let feedAvailable = {}, feedSelected = [];
function feedRender() {
  const all = {...feedAvailable};
  feedSelected.filter(f => !all[f]).forEach(f => all[f] = f.replace(/^https?:\/\//, '').slice(0, 40));
  $('feedList').innerHTML = Object.entries(all).map(([id, name]) =>
    `<label class="check"><input type="checkbox" value="${escapeHtml(id)}" ${feedSelected.includes(id) ? 'checked' : ''}>${escapeHtml(name)}</label>`).join('');
}
$('feedList').addEventListener('change', () => feedSave(false));
async function feedLoad() {
  try { const d = await getJson('/api/news/feeds'); feedAvailable = d.available || {}; feedSelected = d.selected || []; feedRender(); }
  catch (e) { $('feedList').innerHTML = '<div class="empty">Could not load your news sources.</div>'; }
}
async function feedSave(addCustom, btn) {
  const chosen = Array.from(document.querySelectorAll('#feedList input:checked')).map(i => i.value);
  const url = val('feedCustom').trim();
  if (addCustom) {
    if (!/^https?:[/][/]/.test(url)) { toast('Enter a feed URL starting with http:// or https://', 'warn'); return; }
    chosen.push(url);
  }
  if (!chosen.length) { toast('Pick at least one news source.', 'warn'); feedRender(); return; }
  setSyncState('feedSync', 'pending', '● saving…');
  const d = await call(btn, '/api/news/feeds', {feeds: chosen}, '', {what: 'News sources'});
  if (!d) { setSyncState('feedSync', 'error', '✕ not saved'); feedRender(); return; }
  feedSelected = d.selected || chosen; $('feedCustom').value = ''; feedRender();
  setSyncState('feedSync', 'synced', '✓ saved, fetching fresh stories');
}
async function resetNews(btn) {
  if (!await uiConfirm('Send AppResetClearAllDataMsg (cmdId 13) to wipe the news slots on the glasses?', {ok: 'Reset news', danger: true})) return;
  call(btn, '/api/reset_news', {}, d => 'News FIFO reset: ' + (d.result ? JSON.stringify(d.result) : 'sent'), {what: 'Reset'});
}
function pushTestNews(btn) {
  call(btn, '/api/push_news', {title: val('testNewsTitle'), source: val('testNewsSource'), content: val('testNewsContent')},
       'Article pushed to the glasses', {what: 'News'});
}

// ───────────────────────── weather ─────────────────────────
function wxShowMode() {
  const auto = val('wxMode') === 'auto';
  $('wxAutoBox').hidden = !auto;
  $('wxManualBox').hidden = auto;
}
function wxShowNow(now) {
  const el = $('wxNow');
  if (!now) { el.hidden = true; return; }
  el.hidden = false;
  el.innerHTML = `<span class="k">Showing</span> ${escapeHtml(now.summary || '')}`;
  homeSum('hsWx', now.summary || 'Not set up yet');
}
async function wxLoad() {
  try {
    const d = await getJson('/api/weather');
    $('wxType').innerHTML = Object.entries(d.types).filter(([k]) => k !== '0')
      .map(([k, n]) => `<option value="${escapeHtml(k)}">${escapeHtml(n)}</option>`).join('');
    const s = d.settings;
    $('wxMode').value = s.mode;
    $('wxUnit').value = s.unit;
    $('wxCity').value = s.city || '';
    $('wxCity').placeholder = s.place ? `automatic: ${s.place}` : 'e.g. Lisbon';
    $('wxTemp').value = s.manual_temp_f;
    $('wxType').value = String(s.manual_type);
    wxShowMode();
    wxShowNow(d.now);
  } catch (e) {}
}
async function wxSave(btn) {
  setSyncState('wxSync', 'pending', '● updating…');
  const d = await call(btn, '/api/weather', {mode: val('wxMode'), unit: val('wxUnit'), city: val('wxCity').trim(),
    manual_temp_f: parseFloat(val('wxTemp') || '72'), manual_type: parseInt(val('wxType')), manual_status: ''},
    d => d.note ? 'Weather saved; sent when the glasses connect' : (d.ok ? 'Weather updated on the glasses' : 'Weather sent, no ack'), {what: 'Weather'});
  if (!d) { setSyncState('wxSync', 'error', '✕ not saved'); return; }
  setSyncState('wxSync', 'synced', d.note ? '● saved (glasses offline)' : (d.ok ? '✓ on glasses' : '● sent, no ack'));
  wxShowNow(d.now);
  wxLoad();
}

// ───────────────────────── stocks (experimental) ─────────────────────────
function stShow(last) {
  const box = $('stQuotes');
  if (!last || !((last.quotes || []).length || (last.errors || []).length)) { box.hidden = true; return; }
  const rows = (last.quotes || []).map(q => `${escapeHtml(q.code)}  ${escapeHtml(Number(q.price).toFixed(2))}  ` +
    `(${q.change_percent >= 0 ? '+' : ''}${escapeHtml(Number(q.change_percent).toFixed(2))}%)  ${escapeHtml(q.name || '')}`);
  const errs = (last.errors || []).map(e => 'error: ' + escapeHtml(e));
  box.innerHTML = rows.concat(errs).join('<br>');
  box.hidden = false;
}
async function stLoad() {
  try {
    const d = await getJson('/api/stocks');
    if (!$('stSymbols').value) $('stSymbols').value = (d.settings.symbols || []).join(', ');
    stShow(d.last);
  } catch (e) { /* hub offline: the banner covers it */ }
}
async function stSend(btn, push) {
  setSyncState('stSync', 'pending', push ? '● sending…' : '● fetching…');
  const d = await call(btn, '/api/stocks', {symbols: val('stSymbols'), push: push},
    d => !push ? `Fetched ${d.quotes.length} quote(s)` : d.note ? 'Fetched; glasses not connected'
       : d.pushed ? 'Stocks acked by the glasses' : 'Stocks sent; not all acked', {what: 'Stocks'});
  if (!d) { setSyncState('stSync', 'error', '✕ failed'); return; }
  stShow(d);
  setSyncState('stSync', d.pushed ? 'synced' : 'idle', d.pushed ? '✓ acked' : (push && !d.note ? '● sent, no ack' : '● fetched'));
}

async function scSend(btn) {
  const symbol = val('scSymbol').trim();
  if (!symbol) { toast('Enter a stock symbol first', 'err'); return; }
  setBusy(btn, true);
  try {
    const d = await postJson('/api/app/stockchart', {symbol: symbol});
    if (d.error) {
      toast(/connect|glasses|session/i.test(d.error) ? 'Glasses not connected: connect them, then send the chart again' : 'Stock chart: ' + d.error, 'err');
      return;
    }
    toast(`Chart for ${d.symbol || symbol.toUpperCase()} sent to your glasses`, 'ok');
  } finally { setBusy(btn, false); }
}

// ───────────────────────── custom widgets (experimental) ─────────────────────────
function cwNums(text) {
  return String(text || '').split(/[,\s;]+/).filter(Boolean).map(Number).filter(n => isFinite(n));
}
function cwType() {
  const t = val('cwType');
  $('cwGraph').hidden = t !== 'graph'; $('cwMetric').hidden = t !== 'metric'; $('cwStock').hidden = t !== 'stock';
  cwPreview();
}
function cwPreview() {
  const c = $('cwPrev'); if (!c || !c.getContext) return;
  const g = c.getContext('2d'), W = c.width, H = c.height, t = val('cwType');
  g.fillStyle = '#000'; g.fillRect(0, 0, W, H); g.fillStyle = g.strokeStyle = '#fff';
  g.textBaseline = 'top';
  if (t === 'metric') {
    g.font = '16px sans-serif'; g.fillStyle = '#a0a0a0'; g.fillText(val('cwMTitle').slice(0, 24), 6, 4);
    const v = val('cwValue').slice(0, 12) || '--'; let sz = 84;
    g.textAlign = 'center'; g.textBaseline = 'middle'; g.fillStyle = '#fff';
    do { g.font = sz + 'px sans-serif'; sz -= 6; } while (sz > 20 && g.measureText(v).width > W - 16);
    g.fillText(v, W / 2, H / 2 + 4);
    g.font = '14px sans-serif'; g.fillStyle = '#787878'; g.textBaseline = 'bottom'; g.fillText(val('cwLabel').slice(0, 30), W / 2, H - 4);
    g.textAlign = 'left'; return;
  }
  g.textAlign = 'left';
  if (t === 'stock') { g.font = '20px sans-serif'; g.fillText((val('cwSymbol') || 'AAPL').toUpperCase().slice(0, 10), 4, 2);
    g.font = '12px sans-serif'; g.fillStyle = '#787878'; g.fillText('price chart is drawn when sent', 4, 60); return; }
  const v = cwNums(val('cwValues'));
  g.font = '20px sans-serif'; g.fillText(val('cwGTitle').slice(0, 14) || 'Graph', 4, 2);
  if (v.length < 2) { g.font = '12px sans-serif'; g.fillStyle = '#787878'; g.fillText('enter at least 2 numbers', 4, 60); return; }
  g.font = '13px sans-serif'; g.textAlign = 'right'; g.fillText(String(+v[v.length - 1].toFixed(2)) + val('cwUnit').slice(0, 6), W - 4, 4); g.textAlign = 'left';
  const top = 30, bot = H - 6, l = 4, r = W - 4, lo = Math.min(...v), hi = Math.max(...v), span = (hi - lo) || 1;
  g.lineWidth = 2; g.beginPath();
  v.forEach((n, i) => { const x = l + (r - l) * i / (v.length - 1), y = bot - (bot - top) * (n - lo) / span; i ? g.lineTo(x, y) : g.moveTo(x, y); });
  g.stroke();
  g.font = '10px sans-serif'; g.fillStyle = '#787878'; g.fillText(String(+hi.toFixed(2)), l, top + 1);
  g.textBaseline = 'bottom'; g.fillText(String(+lo.toFixed(2)), l, bot);
}
async function cwSend(btn) {
  const t = val('cwType'); let url = '/api/app/widget', body;
  if (t === 'stock') {
    const symbol = val('cwSymbol').trim();
    if (!symbol) { toast('Enter a stock symbol first', 'err'); return; }
    url = '/api/app/stockchart'; body = {symbol: symbol};
  } else if (t === 'metric') {
    if (!val('cwValue').trim()) { toast('Enter a value first', 'err'); return; }
    body = {type: 'metric', title: val('cwMTitle'), value: val('cwValue').trim(), label: val('cwLabel')};
  } else {
    const nums = val('cwValues').trim(), u = val('cwUrl').trim();
    if (!nums && !u) { toast('Enter some numbers or a data URL first', 'err'); return; }
    body = {type: 'graph', title: val('cwGTitle'), unit: val('cwUnit')};
    if (nums) body.values = nums; else body.url = u;
  }
  setBusy(btn, true);
  try {
    const d = await postJson(url, body);
    if (d.error) {
      toast(/connect|glasses|session/i.test(d.error) ? 'Glasses not connected: connect them, then send again' : 'Widget: ' + d.error, 'err');
      return;
    }
    toast('Widget sent to your glasses', 'ok');
  } finally { setBusy(btn, false); }
}
document.addEventListener('DOMContentLoaded', () => { try { cwType(); } catch (e) { /* preview is optional */ } });

// ───────────────────────── health + watchface (experimental) ─────────────────────────
const HL_FIELDS = ['steps', 'step_goal', 'calories', 'calorie_goal', 'heart_rate', 'heart_rate_avg', 'spo2', 'spo2_avg', 'sleep_minutes', 'sleep'];
async function hlLoad() {
  try {
    const d = await getJson('/api/health');
    HL_FIELDS.forEach(f => { if (d.settings[f] !== undefined && $('hl_' + f).value === '') $('hl_' + f).value = d.settings[f]; });
    $('hlShowCard').checked = d.settings.show_card !== false;
  } catch (e) { /* hub offline */ }
}
async function hlSend(btn) {
  const body = {show_card: $('hlShowCard').checked};
  HL_FIELDS.forEach(f => { body[f] = val('hl_' + f); });
  setSyncState('hlSync', 'pending', '● sending…');
  const d = await call(btn, '/api/health', body,
    d => d.note ? 'Health saved; sent when your glasses connect' : (d.ok ? 'Health sent' : 'Health sent, but the glasses did not confirm it'), {what: 'Health'});
  if (!d) { setSyncState('hlSync', 'error', '✕ failed'); return; }
  setSyncState('hlSync', d.ok ? 'synced' : 'idle', d.note ? '● saved' : (d.ok ? '✓ sent' : '● sent, not confirmed'));
}
function wfShowInfo(info, note) {
  const box = $('wfInfo');
  box.innerHTML = info ? `${info.exists ? 'A custom layout is on your glasses' : 'Your glasses use the built-in layout'}<span class="dev-only"> · version ${escapeHtml(info.version || '–')} · hash ${escapeHtml(info.hash || '–')}</span>`
                       : escapeHtml(note || 'no reply');
  box.hidden = false;
}
function wfPreview() {
  const box = $('wfPreview'); if (!box) return;
  const style = parseInt(val('wfStyle')), pos = {left: 'l', center: 'c', right: 'r'}[val('wfPos')] || 'c';
  const nm = v => escapeHtml(String(v || 'none').replace(/_/g, ' '));
  $('wfStyle3Opts').hidden = style !== 3;
  $('wfLeft').disabled = $('wfRight').disabled = style === 3;
  let h;
  if (style === 3) {
    h = `<div class="wfRow ${pos}"><span class="wfClock">10:09</span></div>`
      + ($('wfDate').checked ? `<div class="wfRow ${pos}"><span class="wfSmall">Fri 9 Oct</span></div>` : '')
      + ($('wfTemp').checked ? `<div class="wfRow ${pos}"><span class="wfSmall">21&deg;C</span></div>` : '');
  } else {
    const l = val('wfLeft'), r = val('wfRight');
    h = `<div class="wfRow ${pos}">${l !== 'none' ? `<span class="wfX">${nm(l)}</span>` : ''}<span class="wfClock">10:09</span>${r !== 'none' ? `<span class="wfX">${nm(r)}</span>` : ''}</div>`;
  }
  box.innerHTML = h;
}
['wfStyle', 'wfPos', 'wfLeft', 'wfRight', 'wfDate', 'wfTemp'].forEach(id => $(id).addEventListener('change', wfPreview));
async function wfLoad() {
  try {
    const d = await getJson('/api/watchface');
    const opts = (list, sel) => list.map(x => `<option value="${escapeHtml(x)}"${x === sel ? ' selected' : ''}>${escapeHtml(x.replace(/_/g, ' '))}</option>`).join('');
    const s = d.settings || {};
    $('wfPos').innerHTML = opts(d.positions, s.pos || 'center');
    $('wfLeft').innerHTML = opts(d.components, s.left || 'temperature');
    $('wfRight').innerHTML = opts(d.components, s.right || 'sunset');
    if (s.style) $('wfStyle').value = String(s.style);
    if (s.date !== undefined) $('wfDate').checked = !!s.date;
    if (s.temp !== undefined) $('wfTemp').checked = !!s.temp;
  } catch (e) { /* hub offline */ }
  wfPreview();
}
async function wfRead(btn) {
  setSyncState('wfSync', 'pending', '● reading…');
  const d = await call(btn, '/api/watchface', {action: 'read'}, d => d.info ? 'Layout info read' : 'No reply from the glasses', {what: 'Watchface'});
  if (!d) { setSyncState('wfSync', 'error', '✕ failed'); return; }
  wfShowInfo(d.info, d.note);
  setSyncState('wfSync', d.info ? 'synced' : 'idle', d.info ? '✓ read' : '● no reply');
}
async function wfUpload(btn) {
  setSyncState('wfSync', 'pending', '● uploading…');
  const d = await call(btn, '/api/watchface', {action: 'upload', style: parseInt(val('wfStyle')), pos: val('wfPos'),
    left: val('wfLeft'), right: val('wfRight'), date: $('wfDate').checked, temp: $('wfTemp').checked, confirm: val('wfConfirm').trim()},
    d => d.ok ? 'Layout applied' : 'The upload did not finish. Try again with your glasses close by.', {what: 'Watchface'});
  $('wfConfirm').value = '';
  if (!d) { setSyncState('wfSync', 'error', '✕ failed'); return; }
  wfShowInfo(d.before, null);
  setSyncState('wfSync', d.ok ? 'synced' : 'error', d.ok ? '✓ uploaded' : '✕ incomplete');
}

// ───────────────────────── built-in apps ─────────────────────────
$('navDir').innerHTML = NAV_DIRECTIONS.map(d =>
  `<option value="${escapeHtml(d)}" ${d === 'TURN_RIGHT' ? 'selected' : ''}>${escapeHtml(d.toLowerCase().replace(/_/g, ' '))}</option>`).join('');
function setAppSync(state, label) { document.querySelectorAll('.appSync').forEach(el => { el.className = 'sync appSync ' + state; el.textContent = label; }); }
async function translateSend(btn) {
  const text = val('trText').trim();
  if (!text) { toast('Translate: enter some text', 'err'); return; }
  const d = await call(btn, '/api/app/translate/text', {text, src: val('trSrc'), dst: val('trDst'), final: true}, 'Translated and sent', {what: 'Translate'});
  if (!d) return;
  const el = $('trResult');
  el.innerHTML = `<span class="k">Translation</span> ${escapeHtml(d.translated)}`;
  el.hidden = false;
  setAppSync('synced', '● ' + d.current + ' open');
}
// Live translate: GET/POST /api/translate/mode {on, src, dst}
let ltLoaded = false, ltBusy = false;
function ltFill(sel, langs, cur) {
  const entries = Array.isArray(langs) ? langs.map(x => (typeof x === 'string' ? [x, x] : [x.code, x.name || x.code]))
                                       : Object.entries(langs || {});
  if (!entries.length) return;
  const known = entries.some(([c]) => String(c).toUpperCase() === String(cur || '').toUpperCase());
  const all = known || !cur ? entries : entries.concat([[cur, cur]]);
  sel.innerHTML = all.map(([c, n]) => `<option value="${escapeHtml(c)}">${escapeHtml(n)}</option>`).join('');
  const m = all.find(([c]) => String(c).toUpperCase() === String(cur || '').toUpperCase());
  if (m) sel.value = m[0];
}
function ltRender(d) {
  ltCur = d || {};
  const st = $('ltState');
  if (d.languages) { ltFill($('ltSrc'), d.languages, d.src); ltFill($('ltDst'), d.languages, d.dst); }
  $('ltOn').checked = !!d.on;
  st.classList.toggle('on', !!d.on);
  const pair = (d.src || '?') + ' → ' + (d.dst || '?');
  st.textContent = d.on
    ? 'On · ' + pair + (d.opened ? ' · Translate is open on your glasses' : conn.connected ? '' : ' · Translate opens when your glasses connect; then use the wake gesture')
    : 'Off · ' + pair;
  tglRender();
  translateTile();
}
let mcRunning = false;
function translateTile() { tileState('translate', mcRunning ? 'Listening now' : ltCur.on ? 'Hands-free translate is on' : ''); }
async function ltLoad() {
  try { ltRender(await getJson('/api/translate/mode')); ltLoaded = true; }
  catch (e) { $('ltState').textContent = 'Could not load the translate settings.'; }
}
async function ltPost(body) {
  if (ltBusy) return;
  ltBusy = true;
  try {
    const d = await postJson('/api/translate/mode', body);
    if (d.error) { toast('Live translate: ' + d.error, 'err'); await ltLoad(); return; }
    ltRender(d);
    if ('on' in body) toast(d.on ? 'Translate on: do the wake gesture and speak' : 'Translate off', 'ok');
  } finally { ltBusy = false; }
}
function ltSet(el) { ltPost({on: el.checked, src: val('ltSrc'), dst: val('ltDst')}); }
function ltLangChanged() { if (ltLoaded) ltPost({src: val('ltSrc'), dst: val('ltDst')}); }

// Continuous microphone translation: /api/translate/live[/start|/stop]; polled while running.
let mcTimer = null, mcBusy = false;
function mcInit() {
  ['Src', 'Dst'].forEach(k => { $('mc' + k).innerHTML = $('tr' + k).innerHTML; });
  $('mcSrc').value = 'EN'; $('mcDst').value = 'ES';
}
mcInit();
function mcRender(d) {
  const run = !!d.running;
  $('mcStart').disabled = run; $('mcStop').disabled = !run;
  $('mcSrc').disabled = run; $('mcDst').disabled = run;
  const st = $('mcState');
  st.classList.toggle('on', run);
  mcRunning = run; translateTile();
  let msg = run ? 'Listening · ' + (d.src || '?') + ' → ' + (d.dst || '?') + (d.utterances ? ' · ' + d.utterances + ' phrases' : '') : 'Not listening';
  if (d.last_error) msg += ' · ' + d.last_error;
  else if (run && d.last_push_error) msg += ' · could not show it on the glasses: ' + d.last_push_error;
  st.textContent = msg;
  if (run) { if ($('mcSrc').value !== d.src && d.src) $('mcSrc').value = d.src; if ($('mcDst').value !== d.dst && d.dst) $('mcDst').value = d.dst; }
  const has = d.last_original || d.last_translated;
  $('mcOut').hidden = !has;
  $('mcOrig').textContent = d.last_original || '';
  $('mcTrans').textContent = d.last_translated || '';
  if (d.mic_available === false) $('mcHelp').hidden = false;
  if (run && !mcTimer) mcTimer = setInterval(mcLoad, 1500);
  if (!run && mcTimer) { clearInterval(mcTimer); mcTimer = null; }
}
async function mcLoad() {
  try { mcRender(await getJson('/api/translate/live')); }
  catch (e) { $('mcState').textContent = 'Could not read the listening state.'; }
}
async function mcStart(btn) {
  if (mcBusy) return;
  mcBusy = true; setBusy(btn, true);
  try {
    const body = {src: val('mcSrc'), dst: val('mcDst')};
    const micSrc = val('mcSource');
    if (micSrc && micSrc !== 'auto') body.source = micSrc;   // omit = backend auto-picks glasses when connected
    const d = await postJson('/api/translate/live/start', body);
    if (d.error) {
      if (d.mic_available === false || /mic|sounddevice|portaudio/i.test(d.error)) {
        $('mcHelp').hidden = false;
        toast('No microphone available on this computer', 'err');
      } else toast('Live translation: ' + d.error, 'err');
      return;
    }
    $('mcHelp').hidden = true;
    toast('Listening: speak, and the translation appears on your glasses', 'ok');
    await mcLoad();
  } finally { mcBusy = false; setBusy(btn, false); mcLoad(); }
}
async function mcStop(btn) {
  setBusy(btn, true);
  try {
    const d = await postJson('/api/translate/live/stop', {});
    if (d.error) toast('Live translation: ' + d.error, 'err'); else toast('Stopped listening', 'ok');
  } finally { setBusy(btn, false); await mcLoad(); }
}
async function appPost(btn, url, body, okText) {
  const d = await call(btn, url, body, okText, {what: 'App'});
  if (d) setAppSync(d.current ? 'synced' : 'idle', d.current ? '● ' + d.current + ' open' : '● no app open');
}

// Navigation with a real route: POST .../navigation/route {to, from}, then .../navigation/step {} for each next turn.
const navRt = {index: -1, of: 0};
function navFriendly(e) {
  e = String(e || '');
  if (/not connected|no app|glasses/i.test(e)) return 'Connect your glasses first, then start directions.';
  if (/from required/i.test(e)) return 'Enter where you start (an address or "lat,lon"): this computer has no GPS.';
  if (/to required/i.test(e)) return 'Enter a destination.';
  if (/route finished/i.test(e)) return 'That was the last step: you have arrived.';
  if (/hub not reachable/i.test(e)) return e;
  if (/^HTTP 5/.test(e) || /geocod|route|found|osrm|nominatim|lookup/i.test(e)) return 'Could not get a route: ' + e;
  return 'Navigation: ' + e;
}
function navFmtDist(m) { m = Number(m) || 0; return m >= 1000 ? (m / 1000).toFixed(1) + ' km' : Math.round(m) + ' m'; }
function navShow(step, index, of, extra) {
  const el = $('navNow');
  const turn = String((step && step.maneuver) || 'straight').replace(/[:_]/g, ' ');
  const road = step && step.road ? ' on ' + step.road : '';
  el.innerHTML = `<span class="k">${escapeHtml(extra || 'Now')} · turn ${index + 1} of ${of}</span>`
    + `<span class="big">${escapeHtml(turn + road)}</span>`;
  el.hidden = false;
  navRt.index = index; navRt.of = of;
  tileState('navigation', index >= of - 1 ? 'Last turn sent' : `Route active · turn ${index + 1} of ${of}`);
  $('navNextBtn').disabled = index >= of - 1;   // enabled only while a route has steps left
}
async function navCall(btn, url, body) {
  if (btn && btn.dataset.busy === '1') return null;
  setBusy(btn, true);
  try {
    const d = await postJson(url, body);
    if (d.error) { toast(navFriendly(d.error), 'err'); return null; }
    return d;
  } finally { setBusy(btn, false); }
}
async function navRoute(btn) {
  const to = val('navTo').trim(), from = val('navFrom').trim();
  if (!from) { toast(navFriendly('from required'), 'err'); return; }
  if (!to) { toast(navFriendly('to required'), 'err'); return; }
  const d = await navCall(btn, '/api/app/navigation/route', {to, from});
  if (!d) return;
  setAppSync(d.current ? 'synced' : 'idle', d.current ? '● ' + d.current + ' open' : '● no app open');
  navShow(d.first, 0, d.steps, 'Route to ' + (d.to || to));
  toast(`Directions ready: ${d.steps} turns. The first one is on your glasses.`, 'ok');
}
async function navNext(btn) {
  const d = await navCall(btn, '/api/app/navigation/step', {});
  if (!d) return;
  setAppSync(d.current ? 'synced' : 'idle', d.current ? '● ' + d.current + ' open' : '● no app open');
  if (d.step) navShow(d.step, d.index, d.of);
  else toast('Turn sent', 'ok');
}

// Teleprompter: read a local text file into the script box (client side only).
$('tpFile').addEventListener('change', async (e) => {
  const f = e.target.files && e.target.files[0];
  if (!f) return;
  if (!/\.(txt|md|text)$/i.test(f.name) && f.type && !/^text\//.test(f.type)) { toast('Please choose a .txt, .md or .text file', 'err'); e.target.value = ''; return; }
  if (f.size > 1024 * 1024) { toast('That file is over 1 MB: too large for a script', 'err'); e.target.value = ''; return; }
  try {
    const t = (await f.text()).replace(/^\uFEFF/, '').replace(/\r\n?/g, '\n');
    if (!t.trim()) { toast('That file is empty', 'err'); e.target.value = ''; return; }
    $('tpScript').value = t; tpCount();
    tpLoadedLen = t.length; $('tpName').textContent = f.name + ' · ' + t.length.toLocaleString() + ' characters';
    toast('Loaded ' + f.name, 'ok');
  } catch (err) { toast('Could not read that file', 'err'); }
  e.target.value = '';   // allow re-opening the same file
});
function tpCount() { const n = val('tpScript').length; $('tpCount').textContent = n ? '(' + n.toLocaleString() + ' characters)' : ''; if (!$('tpFile').files.length && n !== tpLoadedLen && tpLoadedLen >= 0) $('tpName').textContent = 'Edited · ' + n.toLocaleString() + ' characters'; }
let tpLoadedLen = -1;
$('tpScript').addEventListener('input', tpCount);
tpCount();

// ───────────────────────── profiles ─────────────────────────
const prof = {data: null, schedDirty: false};
const DAY_NAMES = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
function profFriendly(e) {
  if (/no active glasses|503/.test(e)) return 'Profiles are saved per pair of glasses. Connect your glasses once first.';
  return e;
}
async function profLoad() {
  let d;
  try { d = await getJson('/api/profiles'); }
  catch (e) { profRender(null, profFriendly(String(e.message || e))); return; }
  profRender(d);
}
function profRender(d, err) {
  const list = $('profList');
  if (!d) {
    prof.data = null;
    list.innerHTML = `<div class="empty">${escapeHtml(err || 'Profiles unavailable')}</div>`;
    $('profActive').textContent = 'Active profile: unknown';
    setSyncState('profSync', 'idle', '● —');
    return;
  }
  prof.data = d;
  $('profActive').innerHTML = d.active ? `<span class="k">Active</span> ${escapeHtml(d.active)}` : '<span class="k">Active</span> none (your current setup is not saved as a profile)';
  homeSum('hsProf', d.active || 'None');
  setSyncState('profSync', d.active ? 'synced' : 'idle', d.active ? '● ' + d.active : '● none');
  const ps = d.profiles || [];
  list.innerHTML = ps.length ? ps.map(p => {
    const when = p.saved_at ? new Date(p.saved_at * 1000).toLocaleString() : '';
    return `<div class="profRow${p.name === d.active ? ' active' : ''}" data-name="${escapeHtml(p.name)}">`
      + `<span class="pn">${escapeHtml(p.name)}${p.name === d.active ? ' <span class="badge ok plain">Active</span>' : ''}</span>`
      + `<span class="pa"><button type="button" class="small" data-act="apply">Apply</button>`
      + `<button type="button" class="warn small" data-act="delete">Delete</button></span>`
      + `<span class="pm">${escapeHtml((p.sections || []).join(', ') || 'empty')}${when ? ' · saved ' + escapeHtml(when) : ''}</span></div>`;
  }).join('') : '<div class="empty">No profiles yet. Set up your dashboard, then save it under a name below.</div>';
  if (!prof.schedDirty) schedRender(d.schedule || {enabled: false, rules: []});
  else schedRefreshOptions();
}
$('profList').addEventListener('click', async (e) => {
  const btn = e.target.closest('button[data-act]');
  if (!btn || btn.disabled) return;
  const name = btn.closest('.profRow').dataset.name;
  if (btn.dataset.act === 'apply') {
    const d = await call(btn, '/api/profiles', {action: 'apply', name}, 'Applied "' + name + '"' + (conn.connected ? '' : ' (reaches the glasses when they connect)'), {what: 'Profiles'});
    if (d) profRender(d);
  } else if (btn.dataset.act === 'delete') {
    if (!await uiConfirm('Delete the profile "' + name + '"? Rules in the schedule that use it will simply be skipped.', {ok: 'Delete', danger: true})) return;
    const d = await call(btn, '/api/profiles', {action: 'delete', name}, 'Deleted "' + name + '"', {what: 'Profiles'});
    if (d) profRender(d);
  }
});
async function profSave(btn) {
  const name = val('profName').trim();
  if (!name) { toast('Profiles: enter a name first', 'err'); return; }
  const exists = prof.data && (prof.data.profiles || []).some(p => p.name.toLowerCase() === name.toLowerCase());
  if (exists && !await uiConfirm('A profile named "' + name + '" exists. Replace it with the current setup?', {ok: 'Replace'})) return;
  const d = await call(btn, '/api/profiles', {action: 'save', name}, 'Saved profile "' + name + '"', {what: 'Profiles'});
  if (d) { $('profName').value = ''; profRender(d); }
}
function schedProfileOptions(selected) {
  const names = ((prof.data && prof.data.profiles) || []).map(p => p.name);
  if (selected && !names.includes(selected)) names.push(selected);
  return names.map(n => `<option value="${escapeHtml(n)}"${n === selected ? ' selected' : ''}>${escapeHtml(n)}</option>`).join('')
    || '<option value="">(no profiles yet)</option>';
}
function schedRuleHtml(r) {
  r = r || {};
  const days = r.days || [];
  return `<div class="ruleRow">`
    + `<select class="rProf" aria-label="Profile">${schedProfileOptions(r.profile)}</select>`
    + `<input type="time" class="rStart" aria-label="From" value="${escapeHtml(r.start || '09:00')}">`
    + `<span class="opt">to</span>`
    + `<input type="time" class="rEnd" aria-label="Until" value="${escapeHtml(r.end || '17:00')}">`
    + `<button type="button" class="icon" data-act="del" aria-label="Remove rule">✕</button>`
    + `<div class="ruleDays">${DAY_NAMES.map((n, i) => `<label><input type="checkbox" class="rDay" value="${i}"${days.includes(i) ? ' checked' : ''}>${n}</label>`).join('')}</div>`
    + `</div>`;
}
function schedRender(s) {
  $('schedOn').checked = !!s.enabled;
  const rules = s.rules || [];
  $('schedRules').innerHTML = rules.length ? rules.map(schedRuleHtml).join('') : '<div class="empty">No rules yet.</div>';
  prof.schedDirty = false;
}
function schedRefreshOptions() {   // keep unsaved edits, only refresh the profile choices
  document.querySelectorAll('#schedRules .rProf').forEach(sel => { const v = sel.value; sel.innerHTML = schedProfileOptions(v); });
}
function schedAddRule() {
  const box = $('schedRules');
  if (!box.querySelector('.ruleRow')) box.innerHTML = '';
  box.insertAdjacentHTML('beforeend', schedRuleHtml({}));
  prof.schedDirty = true;
}
$('schedRules').addEventListener('click', (e) => {
  const b = e.target.closest('button[data-act="del"]');
  if (b) { b.closest('.ruleRow').remove(); prof.schedDirty = true; }
});
$('schedRules').addEventListener('input', () => { prof.schedDirty = true; });
$('schedOn').addEventListener('change', () => { prof.schedDirty = true; });
async function schedSave(btn) {
  const rules = Array.from(document.querySelectorAll('#schedRules .ruleRow')).map(row => {
    const days = Array.from(row.querySelectorAll('.rDay:checked')).map(c => parseInt(c.value));
    const r = {profile: row.querySelector('.rProf').value, start: row.querySelector('.rStart').value, end: row.querySelector('.rEnd').value};
    if (days.length) r.days = days;
    return r;
  });
  if (rules.some(r => !r.profile || !r.start || !r.end)) { toast('Schedule: every rule needs a profile and both times', 'err'); return; }
  const d = await call(btn, '/api/profiles/schedule', {enabled: $('schedOn').checked, rules}, 'Schedule saved', {what: 'Schedule'});
  if (d) { prof.schedDirty = false; profRender(d); }
}

// ───────────────────────── glasses status + settings ─────────────────────────
function showGlassStatus(s) {
  conn.status = s || {}; renderConn();
  const el = $('glassStatus');
  if (!s || !Object.keys(s).length) { el.hidden = true; return; }
  const parts = [];
  if (s.battery !== undefined) parts.push(`Battery ${escapeHtml(s.battery)}%${s.charging ? ' (charging)' : ''}`);
  if (s.worn !== undefined) parts.push(s.worn ? 'Worn' : 'Not worn');
  if (s.case_battery !== undefined) parts.push(`Case ${escapeHtml(s.case_battery)}%`);
  if (s.right_version || s.left_version) parts.push(`Software ${escapeHtml(s.right_version || s.left_version)}`);
  if (s.brightness_auto !== undefined) parts.push(s.brightness_auto ? 'Auto brightness' : `Brightness ${escapeHtml(s.brightness_level)}`);
  if (s.silent_mode) parts.push('Silent');
  if (s.display_timeout !== undefined) parts.push(s.display_timeout === 'never' ? 'Screen stays on' : `Screen off after ${escapeHtml(s.display_timeout)} s`);
  el.innerHTML = `<span class="k">${conn.connected ? 'Now' : 'Last seen'}</span> ` + parts.join(' · ');
  el.hidden = !parts.length;
}
function glassesRefresh(btn) { call(btn, '/api/glasses/refresh', {}, 'Checking your glasses…', {what: 'Refresh'}); }
async function glassesRestart(btn) {
  if (!await uiConfirm('Restart the glasses? The connection drops and the hub reconnects by itself.', {ok: 'Restart', danger: true})) return;
  call(btn, '/api/device/restart', {}, 'Restart sent; the glasses will reconnect', {what: 'Restart'});
}
let setLoaded = false;
function setDirty() { if (setLoaded) setSyncState('setSync', 'pending', '● changed, not applied'); }
function renderHubInfo(d, caps) {
  const f = (d && d.files) || {};
  const rows = [['API keys', f.env_file], ['Page access token', f.token_file], ['Hub settings', f.hub_config],
                ['Glasses and history', f.data_dir], ['Log file', f.log_file]].filter(r => r[1]);
  $('hubFiles').innerHTML = rows.map(([k, v]) => `<dt>${escapeHtml(k)}</dt><dd><code>${escapeHtml(v)}</code></dd>`).join('') || '<dt>…</dt><dd></dd>';
  if (caps) {
    const yes = '<span class="pill ok">Ready</span>', no = '<span class="pill warn">Missing</span>';
    $('hubKeys').innerHTML = `<dt>Speech-to-text key</dt><dd>${caps.deepgram_key ? yes : no}</dd>`
      + `<dt>Claude key</dt><dd>${caps.anthropic_key ? yes : no}</dd>`
      + `<dt>Microphone decoder</dt><dd>${caps.audio_decoder ? yes : no}</dd>`;
  }
}
let settingsData = null;
async function setLoad() {
  try {
    const d = await getJson('/api/settings');
    settingsData = d;
    const br = d.brightness_range || [1, 50];
    $('setBright').min = br[0]; $('setBright').max = br[1];
    $('setTimeout').innerHTML = d.timeouts.map(t => `<option value="${escapeHtml(t)}">${t === 'never' ? 'never' : escapeHtml(t) + ' s'}</option>`).join('');
    $('setLang').innerHTML = Object.entries(d.languages).map(([i, n]) => `<option value="${escapeHtml(i)}">${escapeHtml(n)}</option>`).join('');
    const s = d.saved || {};
    if (s.brightness !== undefined) $('setBright').value = s.brightness;
    $('setBrightVal').textContent = $('setBright').value;
    $('setAuto').checked = !!s.auto_brightness;
    $('setSilent').checked = !!s.silent_mode;
    $('setWear').checked = s.wear_detection === undefined ? true : !!s.wear_detection;
    $('setHeadUp').checked = !!s.head_up;
    if (s.head_up_angle !== undefined) $('setHeadAngle').value = s.head_up_angle;
    if (s.display_timeout !== undefined) $('setTimeout').value = String(s.display_timeout);
    if (s.language !== undefined) $('setLang').value = String(s.language);
    $('setKeepLid').checked = !!(d.hub || {}).keep_connected_lid_closed;
    setSyncState('setSync', 'idle', Object.keys(s).length ? '● saved for this pair' : '● glasses defaults');
    showGlassStatus(d.status);
    tglRender();
    renderHubInfo(d, aiCaps);
    setLoaded = true;
  } catch (e) {}
}
async function setApply(btn) {
  const t = val('setTimeout');
  const body = {
    auto_brightness: $('setAuto').checked, brightness: parseInt(val('setBright')),
    silent_mode: $('setSilent').checked, wear_detection: $('setWear').checked,
    head_up: $('setHeadUp').checked, head_up_angle: Math.max(0, Math.min(60, parseInt(val('setHeadAngle')) || 0)),
    display_timeout: t === 'never' ? 'never' : parseInt(t), language: parseInt(val('setLang')),
  };
  setSyncState('setSync', 'pending', '● sending…');
  const d = await call(btn, '/api/settings', body, 'Settings applied and saved for this pair', {what: 'Settings'});
  setSyncState('setSync', d ? 'synced' : 'error', d ? '✓ applied' : '✕ not applied');
  if (d) settingsSaved(d.saved);
}
async function setKeepLid() {
  const box = $('setKeepLid');
  const on = box.checked;
  box.disabled = true;
  setSyncState('lidSync', 'pending', '● saving…');
  const d = await call(null, '/api/settings', {keep_connected_lid_closed: on}, '', {what: 'Lid setting'});
  box.disabled = false;
  if (!d) { box.checked = !on; setSyncState('lidSync', 'error', '✕ not saved'); return; }
  setSyncState('lidSync', 'synced', '✓ saved');
}
function notifySetup(btn) { call(btn, '/api/notify_setup', {disp_time: 5}, 'Notifications turned on for your glasses', {what: 'Notifications'}); }
async function notifySend(btn) {
  setSyncState('ntSync', 'pending', '● sending…');
  const d = await call(btn, '/api/notify_send', {title: val('ntTitle'), message: val('ntMessage'), display_name: val('ntApp')},
                       'Notification sent: look at your glasses', {what: 'Notification'});
  setSyncState('ntSync', d ? 'synced' : 'error', d ? '✓ sent' : '✕ failed');
}

// ───────────────────────── glasses / device database ─────────────────────────
let devFound = [], devList = [];
async function devLoad() {
  try {
    const d = await getJson('/api/devices');
    const el = $('devList');
    el.innerHTML = d.devices.map(g => {
      const id = Number(g.id), active = g.id === d.active;
      const seen = g.last_seen ? 'Last connected ' + new Date(g.last_seen * 1000).toLocaleString([], {month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit'}) : 'Not connected yet';
      return `<div class="itemRow devRow${active ? ' active' : ''}" data-id="${id}">
        <span class="devIco" aria-hidden="true">${svgIco('glasses')}</span>
        <div class="itemMain">
          <b>${escapeHtml(g.name)}</b> ${active ? '<span class="badge ok plain">In use</span>' : ''}
          <div class="hint flush">${escapeHtml(seen)}${g.firmware ? ' · Software ' + escapeHtml(g.firmware) : ''}</div>
          <div class="hint flush dev-only">pair ${escapeHtml(g.pair_id)} · R ${escapeHtml(g.right_mac || '?')} · L ${escapeHtml(g.left_mac || '?')}</div>
        </div>
        <span class="rowBtns">
        ${active ? '' : '<button class="small" data-act="use">Use</button>'}
        <button class="secondary small" data-act="rename">Rename</button>
        ${active ? '' : '<button class="warn small" data-act="forget">Forget</button>'}
        </span>
      </div>`;
    }).join('') || '<div class="empty">No glasses saved yet. Choose Find glasses, or follow the setup guide.</div>';
    devList = d.devices;
    wizSync(d.devices.length === 0);
    const act = d.devices.find(g => g.id === d.active);
    conn.name = act ? act.name : ''; conn.connected = !!d.connected; conn.hub = true; renderConn();
    setSyncState('devSync', d.connected ? 'synced' : 'idle', d.connected ? '● connected' : '● not connected');
  } catch (e) {
    setSyncState('devSync', 'error', '✕ not loaded');
    $('devList').innerHTML = '<div class="empty">Could not load your glasses.</div>';
    toast('Could not load your glasses list: ' + ((e && e.message) || e), 'err');
  }
}
$('devList').addEventListener('click', (e) => {
  const btn = e.target.closest('button[data-act]');
  if (!btn) return;
  const id = Number(btn.closest('[data-id]').dataset.id);
  const act = btn.dataset.act;
  if (act === 'use') devSelect(id, btn);
  else if (act === 'rename') devRename(id, btn);
  else if (act === 'forget') devForget(id, btn);
});
async function devScan(btn) {
  const el = $('devFound');
  el.innerHTML = '<div class="empty scanning">Looking for glasses nearby (about 8 seconds)… Glasses that are connected right now do not show up.</div>';
  const d = await call(btn, '/api/devices/scan', {}, '', {what: 'Scan'});
  if (!d) { el.innerHTML = ''; return; }
  devFound = d.found || [];
  el.innerHTML = devFound.map((f, i) => foundRow(f, i, 'data-act="add"')).join('')
    || '<div class="empty">No Even G2 glasses found. Take them out of the case, or disconnect them from other devices, then try again.</div>';
}
$('devFound').addEventListener('click', (e) => {
  const btn = e.target.closest('button[data-act="add"]');
  if (btn) devAdd(Number(btn.closest('[data-i]').dataset.i), btn);
});
// One scan result: both lenses are needed to add a pair.
function foundRow(f, i, act) {
  const both = f.right_mac && f.left_mac;
  return `<div class="itemRow devRow" data-i="${i}"><span class="devIco" aria-hidden="true">${svgIco('glasses')}</span>`
    + `<div class="itemMain"><b>Even G2 · ${escapeHtml(f.pair_id)}</b>`
    + `<div class="hint flush">${both ? 'Both lenses found' : (f.right_mac ? 'Only the right lens found' : 'Only the left lens found') + ': take both out of the case'}</div>`
    + `<div class="hint flush dev-only">R ${escapeHtml(f.right_mac || 'not seen')} · L ${escapeHtml(f.left_mac || 'not seen')}</div></div>`
    + (both ? `<button class="small" ${act} data-i="${i}">${f.known_id ? 'Update' : 'Add'}</button>` : '') + '</div>';
}
async function devAdd(i, btn) {
  const f = devFound[i];
  if (!f) return;
  const d = await call(btn, '/api/devices/add', {pair_id: f.pair_id, right_mac: f.right_mac, left_mac: f.left_mac}, 'Glasses saved', {what: 'Add'});
  if (!d) return;
  $('devFound').innerHTML = '';
  if (await uiConfirm('Glasses saved. Use them now?', {ok: 'Use now'})) await devSelect(d.id);
  devLoad();
}
async function devSelect(id, btn) { await call(btn, '/api/devices/select', {id}, 'Switching to these glasses…', {what: 'Switch'}); devLoad(); }
async function devRename(id, btn) {
  const name = (devList.find(g => g.id === id) || {}).name || '';
  const n = await uiPrompt('Name for these glasses:', name, {ok: 'Rename'});
  if (n && n.trim() && n !== name) { await call(btn, '/api/devices/rename', {id, name: n.trim()}, 'Renamed', {what: 'Rename'}); devLoad(); }
}
async function devForget(id, btn) {
  if (!await uiConfirm('Forget these glasses? Their saved settings and Even AI history are deleted.', {ok: 'Forget', danger: true})) return;
  await call(btn, '/api/devices/forget', {id}, 'Glasses forgotten', {what: 'Forget'}); devLoad();
}

// ───────────────────────── first-run wizard ─────────────────────────
const WIZ_STEPS = ['Bluetooth', 'Get ready', 'Find', 'Connect', 'Even AI'];
const wiz = {open: false, step: 1, doctor: null, doctorErr: '', found: null, scanning: false, adding: false};
function wizDismissed() { try { return localStorage.getItem('g2hub.wizard') === 'done'; } catch (e) { return false; } }
// Called by devLoad: show the guide while no glasses are saved (unless dismissed); keep it open once started.
function wizSync(noGlasses) {
  if (noGlasses && !wiz.open && !wizDismissed()) { wiz.open = true; wiz.step = 1; wizDoctor(); }
  wizRender();
}
function wizClose(remember) {
  wiz.open = false;
  if (remember) { try { localStorage.setItem('g2hub.wizard', 'done'); } catch (e) {} }
  wizRender();
  connPanelRender();
}
function wizReopen() { try { localStorage.removeItem('g2hub.wizard'); } catch (e) {} wiz.open = true; wiz.step = 1; wizDoctor(); wizRender(); connPanelRender(); go('home', {push: true}); }
async function wizDoctor() {
  wiz.doctor = null; wiz.doctorErr = '';
  wizRender();
  try { wiz.doctor = await getJson('/api/doctor'); } catch (e) { wiz.doctorErr = (e && e.message) || String(e); }
  wizRender();
}
function checkRow(c) {
  return `<div class="chk"><span class="${c.ok ? 'y' : 'n'}">${c.ok ? '✓' : '✗'}</span> ${escapeHtml(c.detail || c.name)}</div>`
    + (!c.ok && c.hint ? `<div class="hint">${escapeHtml(c.hint)}</div>` : '');
}
function wizRender() {
  const el = $('wizard');
  if (!el) return;
  if (!wiz.open) {
    el.hidden = true;
    return;
  }
  el.hidden = false;
  const st = wiz.step;
  const steps = WIZ_STEPS.map((n, i) => `<span class="${i + 1 === st ? 'cur' : i + 1 < st ? 'done' : ''}">${i + 1}. ${escapeHtml(n)}</span>`).join('');
  let body = '', nav = '';
  if (st === 1) {
    if (wiz.doctorErr) body = `<p>Could not run the check: ${escapeHtml(wiz.doctorErr)}</p>`;
    else if (!wiz.doctor) body = '<p>Checking Bluetooth on this computer…</p>';
    else {
      const c = (wiz.doctor.checks || []).find(x => x.name === 'bluetooth_adapter');
      body = c ? checkRow(c) : '<p>No Bluetooth result.</p>';
    }
    nav = '<button class="secondary small" data-w="recheck">Check again</button><button class="small" data-w="next">Next</button>';
  } else if (st === 2) {
    body = '<p>Take your glasses out of the case. If the Even app on your phone is connected to them, close it or turn off the phone\'s Bluetooth: glasses can talk to one device at a time.</p>';
    nav = '<button class="secondary small" data-w="back">Back</button><button class="small" data-w="next">Next</button>';
  } else if (st === 3) {
    if (wiz.scanning) body = '<p>Looking for glasses nearby (about 8 seconds)…</p>';
    else if (wiz.found === null) body = '<p>Choose Find to look for glasses nearby.</p>';
    else if (!wiz.found.length) body = '<p>No Even G2 glasses found. Check the previous step and try again.</p>';
    else body = wiz.found.map((f, i) => foundRow(f, i, 'data-w="add"')).join('');
    nav = '<button class="secondary small" data-w="back">Back</button><button class="small" data-w="scan"' + (wiz.scanning ? ' disabled' : '') + '>Find</button>';
  } else if (st === 4) {
    if (conn.connected) body = '<p><span class="chk"><span class="y">✓</span></span> Connected. Your glasses are ready to use.</p>';
    else {
      const c = CAUSES[conn.cause];
      body = '<p>Saved. Waiting for the glasses to connect…</p>' + (c ? `<p><b>${escapeHtml(c[0])}</b><br>${escapeHtml(c[1])}</p>` : '');
    }
    nav = '<button class="small" data-w="next">' + (conn.connected ? 'Next' : 'Skip') + '</button>';
  } else {
    body = '<p>Optional: add your keys to use Even AI and Translate. You can also do this later in Settings → AI services.</p>'
      + '<label for="wizAnth">Anthropic API key</label><input type="password" id="wizAnth" autocomplete="off">'
      + '<label for="wizDg">Deepgram API key</label><input type="password" id="wizDg" autocomplete="off">';
    nav = '<button class="small" data-w="keys">Save keys</button><button class="secondary small" data-w="done">Finish</button>';
  }
  const keep = {a: ($('wizAnth') || {}).value || '', d: ($('wizDg') || {}).value || ''};
  el.innerHTML = `<div class="wizHead"><b>Set up your glasses</b><span class="push"><button class="secondary small" data-w="dismiss" title="Hide this guide">Not now</button></span></div>`
    + `<div class="wizSteps">${steps}</div>${body}<div class="row">${nav}</div>`;
  if ($('wizAnth')) { $('wizAnth').value = keep.a; $('wizDg').value = keep.d; }
}
$('wizard').addEventListener('click', async (e) => {
  const b = e.target.closest('button[data-w]');
  if (!b) return;
  const w = b.dataset.w;
  if (w === 'next') { wiz.step = Math.min(5, wiz.step + 1); if (wiz.step === 3) { wiz.found = null; } wizRender(); }
  else if (w === 'back') { wiz.step = Math.max(1, wiz.step - 1); wizRender(); }
  else if (w === 'recheck') wizDoctor();
  else if (w === 'dismiss') wizClose(true);
  else if (w === 'done') wizClose(true);
  else if (w === 'scan') {
    wiz.scanning = true; wizRender();
    const d = await call(null, '/api/devices/scan', {}, '', {what: 'Scan'});
    wiz.scanning = false; wiz.found = d ? (d.found || []) : null;
    wizRender();
  } else if (w === 'add') {
    const f = (wiz.found || [])[Number(b.dataset.i)];
    if (!f) return;
    const d = await call(b, '/api/devices/add', {pair_id: f.pair_id, right_mac: f.right_mac, left_mac: f.left_mac}, 'Glasses saved', {what: 'Add'});
    if (!d) return;
    await call(null, '/api/devices/select', {id: d.id}, 'Connecting to your glasses…', {what: 'Switch'});
    wiz.step = 4; wizRender(); devLoad(); statusLoad();
  } else if (w === 'keys') {
    if (await keysSave(b, 'wizAnth', 'wizDg')) wizClose(true);
  }
});

// ───────────────────────── API keys + diagnostics ─────────────────────────
function keyStateRender(checks) {
  const get = (n) => (checks || []).find(c => c.name === n);
  const row = (label, c) => `<dt>${label}</dt><dd>${c ? (c.ok ? '<span class="pill ok">Saved</span>' : '<span class="pill warn">Not set</span>') : '…'}</dd>`;
  $('keyState').innerHTML = row('Anthropic (Claude)', get('anthropic_key')) + row('Deepgram (speech-to-text)', get('deepgram_key'));
}
async function keysLoad() {
  try { keyStateRender((await getJson('/api/doctor')).checks); }
  catch (e) { $('keyState').innerHTML = '<dt>Keys</dt><dd>could not be checked</dd>'; }
}
// Returns true when something was saved. Never logs or echoes key values.
async function keysSave(btn, idA, idD) {
  const body = {}, a = val(idA).trim(), dg = val(idD).trim();
  if (a) body.anthropic = a;
  if (dg) body.deepgram = dg;
  if (!a && !dg) { toast('Type a key first', 'warn'); return false; }
  const d = await call(btn, '/api/keys', body, r => 'Keys saved' + (r.note ? ': ' + r.note : ''), {what: 'Keys'});
  if (!d) return false;
  $(idA).value = ''; $(idD).value = '';
  keyStateRender([{name: 'anthropic_key', ok: !!d.anthropic_set}, {name: 'deepgram_key', ok: !!d.deepgram_set}]);
  return true;
}
async function doctorRun(btn) {
  setBusy(btn, true);
  try {
    const d = await getJson('/api/doctor');
    $('doctorOut').innerHTML = (d.checks || []).map(checkRow).join('')
      + `<div class="hint">${d.ok ? 'Everything looks good.' : 'Some items need attention.'}</div>`;
    keyStateRender(d.checks);
  } catch (e) {
    toast('Check failed: ' + ((e && e.message) || e), 'err');
  } finally { setBusy(btn, false); }
}
async function diagCopy(btn) {
  setBusy(btn, true);
  try {
    const r = await fetch('/api/diagnostics');
    if (!r.ok) throw new Error('HTTP ' + r.status);
    const text = await r.text();
    let ok = false;
    try { await navigator.clipboard.writeText(text); ok = true; } catch (e) { ok = false; }
    if (!ok) {
      const ta = document.createElement('textarea');
      ta.value = text; ta.style.position = 'fixed'; ta.style.opacity = '0';
      document.body.appendChild(ta); ta.select();
      try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
      ta.remove();
    }
    toast(ok ? 'Report copied to the clipboard' : 'Could not copy; open /api/diagnostics in a new tab', ok ? 'ok' : 'err');
  } catch (e) {
    toast('Diagnostics failed: ' + ((e && e.message) || e), 'err');
  } finally { setBusy(btn, false); }
}

// ───────────────────────── Even AI ─────────────────────────
const AI_PHASES = {idle: ['idle', '● idle'], open: ['synced', '● open'], listening: ['pending', '● listening…'],
  transcribing: ['pending', '● transcribing…'], heard: ['pending', '● heard'], thinking: ['pending', '● thinking…'],
  answered: ['synced', '✓ answered'], error: ['error', '✕ error']};
let aiSaveTimer = null, aiLoaded = false, aiCaps = null, aiEnvFile = '~/.config/g2hub/.env';
// Only warn about what the chosen mode actually needs.
function aiShowCaps() {
  const c = aiCaps, el = $('aiCaps');
  if (!c) { el.hidden = true; return; }
  const m = val('aiMode'), listen = $('aiListen').checked && m !== 'off';
  const need = [];
  const keys = [];
  if (listen && !c.audio_decoder) need.push('the microphone audio decoder (start the hub with .venv/bin/python, see docs/hub.md)');
  const localStt = val('aiStt') === 'local';
  if (listen && localStt && !c.stt_local) need.push("offline speech-to-text (pip install -e '.[stt-local]'; Deepgram is used instead if its key is saved)");
  if (listen && !localStt && !c.deepgram_key) keys.push('a Deepgram key (to hear your question)');
  if (m === 'claude' && !c.anthropic_sdk) need.push('the anthropic Python package');
  if (m === 'claude' && !c.anthropic_key) keys.push('an Anthropic key (for Claude answers)');
  el.hidden = !need.length && !keys.length;
  el.innerHTML = (keys.length ? `This mode needs ${keys.map(escapeHtml).join(' and ')}. <button type="button" class="linkBtn" data-go="settings">Add it in Settings → AI services</button>` : '')
    + (need.length ? `<div>Also missing on this computer: ${need.map(escapeHtml).join('; ')}.</div>` : '')
    + `<div class="dev-only hint">Keys file: <code>${escapeHtml(aiEnvFile)}</code></div>`;
}
function aiShowModeBoxes() {
  const m = val('aiMode');
  $('aiCannedBox').hidden = m !== 'canned';
  $('aiClaudeBox').hidden = m !== 'claude';
  $('aiSttModelBox').hidden = val('aiStt') !== 'local';
  aiShowCaps();
}
function aiSave() {
  aiShowModeBoxes();
  if ($('vcList')) $('vcList').classList.toggle('vcOff', !$('aiVoice').checked);
  if (!aiLoaded) return;
  clearTimeout(aiSaveTimer);
  $('aiSaved').textContent = '';
  aiSaveTimer = setTimeout(async () => {
    const d = await postJson('/api/ai_settings', {
      mode: val('aiMode'), listen: $('aiListen').checked,
      show_question: $('aiShowQ').checked, listen_seconds: Math.max(2, Math.min(30, parseInt(val('aiListenS')) || 20)),
      canned_reply: val('aiCanned'), model: val('aiModel'), effort: val('aiEffort'), system: val('aiSystem'),
      tools: $('aiTools').checked, voice_shortcuts: $('aiVoice').checked,
      stt_backend: val('aiStt'), stt_model: val('aiSttModel') || 'base',
    });
    if (d.error) toast('Even AI settings: ' + d.error, 'err');
    else { $('aiSaved').textContent = '✓ Saved'; aiTile(); }
  }, 600);
}
const AI_MODES = {off: 'Off', enter: 'Opens without answering', canned: 'Auto-reply', claude: 'Answers with Claude'};
function aiTile() { const m = val('aiMode'); tileState('even-ai', m && m !== 'off' ? AI_MODES[m] || '' : ''); }
function aiSetPhase(ev) {
  const [cls, label] = AI_PHASES[ev.phase] || ['idle', '● ' + ev.phase];
  setSyncState('aiPhase', cls, ev.speaking ? '● hearing speech…' : label);
  const live = $('aiLive');
  if (ev.question || ev.reply || ev.message) {
    live.hidden = false;
    live.innerHTML = (ev.question ? `<div><span class="k">You</span> ${escapeHtml(ev.question)}</div>` : '') +
      (ev.reply ? `<div><span class="k">Even AI</span> ${escapeHtml(ev.reply)}</div>` : '') +
      (ev.message ? `<div class="bad-t">${escapeHtml(ev.message)}</div>` : '');
  }
}
async function aiLoad() {
  try {
    const d = await getJson('/api/ai_settings');
    const s = d.settings;
    $('aiMode').value = s.mode;
    $('aiListen').checked = s.listen;
    $('aiShowQ').checked = s.show_question;
    $('aiListenS').value = s.listen_seconds;
    $('aiCanned').value = s.canned_reply;
    $('aiModel').innerHTML = Object.entries(d.models || {})
      .map(([id, label]) => `<option value="${escapeHtml(id)}">${escapeHtml(label)}</option>`).join('');
    $('aiModel').value = s.model;
    $('aiTools').checked = s.tools !== false;
    $('aiVoice').checked = s.voice_shortcuts !== false;
    vcRender(d.voice_shortcuts);
    $('aiToolList').textContent = 'Tools: ' + (d.tools || []).join(', ');
    $('aiEffort').value = s.effort;
    $('aiStt').value = s.stt_backend || 'deepgram';
    $('aiSttModel').value = s.stt_model || 'base';
    $('aiSystem').value = s.system;
    aiCaps = d.capabilities || null;
    if (d.env_file) aiEnvFile = d.env_file;
    aiShowModeBoxes();
    renderHubInfo(settingsData, aiCaps);
    aiSetPhase(d.phase || {phase: 'idle'});
    aiLoaded = true;
    aiTile();
  } catch (e) { vcRender([]); }
  aiLoadHistory();
}
const VC_TITLES = {
  close_display: 'Hide the display', show_dashboard: 'Show the dashboard', show_weather: 'Show the weather',
};
function vcTitle(e) {
  const a = e.action || '', args = e.args || {};
  if (a === 'adjust_brightness') return (args.delta || 0) < 0 ? 'Dimmer' : 'Brighter';
  if (a === 'set_brightness') return args.auto ? 'Auto brightness' : 'Set brightness';
  if (a === 'set_silent_mode') return args.on === false ? 'Silent mode off' : 'Silent mode on';
  return VC_TITLES[a] || a.replace(/_/g, ' ').replace(/^./, c => c.toUpperCase());
}
function vcRender(list) {
  const box = $('vcList');
  if (!box) return;
  if (!Array.isArray(list) || !list.length) { box.innerHTML = '<div class="empty">No voice commands are available.</div>'; return; }
  box.innerHTML = list.map(e => {
    const ph = (e.phrases || []);
    const shown = ph.slice(0, 3).map(p => `<span class="vcpill">${escapeHtml(p)}</span>`).join('');
    const more = ph.length > 3 ? `<span class="vcMore" title="${escapeHtml(ph.slice(3).join(', '))}">+${ph.length - 3} more</span>` : '';
    return `<div class="vcRow"><span class="vcAct">${escapeHtml(vcTitle(e))}</span><span class="vcPh">${shown}${more}</span></div>`;
  }).join('') + '<div class="hint">Also: "brightness 30" sets a level from 1 to 50. Politeness words ("please", "could you") are ignored.</div>';
  box.classList.toggle('vcOff', !$('aiVoice').checked);
}
// Voice command test: POST /api/ai/voice_test {text} -> {matched, action, args, result|error}
async function voiceTest(btn) {
  const text = val('vtText').trim();
  const out = $('vtOut');
  if (!text) { $('vtText').focus(); return; }
  setBusy(btn, true);
  let d;
  try { d = await postJson('/api/ai/voice_test', {text}); } finally { setBusy(btn, false); }
  out.hidden = false;
  if (d.error && d.matched === undefined) { out.innerHTML = `<div class="vtBad">${escapeHtml(d.error)}</div>`; return; }
  if (!d.matched) { out.innerHTML = '<div class="vtNone">Not a voice command: Even AI would answer it as a normal question.</div>'; return; }
  const args = d.args && Object.keys(d.args).length ? ' ' + JSON.stringify(d.args) : '';
  out.innerHTML = `<div class="vtHead"><b>${escapeHtml(vcTitle(d))}</b><span class="dev-only opt"> · ${escapeHtml(d.action)}${escapeHtml(args)}</span></div>`
    + (d.error ? `<div class="vtBad">Tool error: ${escapeHtml(d.error)}</div>`
               : `<div class="vtRes">${escapeHtml(d.result == null ? '(done)' : d.result)}</div>`);
}
async function aiLoadHistory() {
  try {
    const d = await getJson('/api/ai_history?limit=30');
    const el = $('aiHistory');
    if (!d.history.length) { el.innerHTML = '<div class="empty">No questions yet. Say "Hey Even" on your glasses, or try one above.</div>'; return; }
    el.innerHTML = d.history.map(h => `
      <div class="aiItem">
        <div class="meta">${escapeHtml(new Date(h.ts * 1000).toLocaleString([], {month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit'}))}${h.source === 'typed' ? ' · typed here' : ''}<span class="dev-only"> · ${escapeHtml(h.mode || '')}${h.model ? ' · ' + escapeHtml(h.model) : ''}</span></div>
        <div class="q">${h.question ? escapeHtml(h.question) : '<i class="none">(nothing heard)</i>'}</div>
        <div class="a">${escapeHtml(h.reply || '')}</div>
        ${h.error ? `<div class="err">${escapeHtml(h.error)}</div>` : ''}
      </div>`).join('');
  } catch (e) { $('aiHistory').innerHTML = '<div class="empty">Could not load recent questions.</div>'; }
}
async function aiTry(btn) {
  const q = val('aiTryQ').trim();
  if (!q) { $('aiTryQ').focus(); return; }
  if (btn && btn.dataset.busy === '1') return;
  aiSetPhase({phase: 'thinking', question: q});
  setBusy(btn, true);
  let d;
  try { d = await postJson('/api/ai_try', {question: q}); } finally { setBusy(btn, false); }
  if (d.error) aiSetPhase({phase: 'error', question: q, message: 'Could not answer: ' + d.error});
  else aiSetPhase({phase: 'answered', question: q, reply: d.reply});
}
function aiForget(btn) { call(btn, '/api/ai_reset', {}, 'Claude conversation forgotten', {what: 'Even AI'}); }
function devPost(btn, url, body, okText) { call(btn, url, body, okText, {what: 'Even AI'}); }

// ───────────────────────── EvenHub apps ─────────────────────────
// hub/routes/evenhub.py. Everything from a manifest is untrusted: escapeHtml.
let ehBusy = false;
function ehMsg(text, bad) {
  const el = $('ehMsg');
  el.classList.toggle('bad', !!bad);
  el.textContent = text || '';
}
async function ehCall(path, body, okText, btn) {
  if (ehBusy) return null;
  ehBusy = true;
  setBusy(btn, true);
  setSyncState('ehSync', 'pending', '● working…');
  try {
    const d = await postJson(path, body);
    if (d.error) throw new Error(d.error);
    const msg = okText ? okText(d) : '✓ done';
    ehMsg(msg, false);
    if (msg) toast(msg.replace(/^✓ /, ''), 'ok');
    setSyncState('ehSync', 'synced', '✓ done');
    return d;
  } catch (e) {
    ehMsg('✕ ' + e.message, true);
    toast('EvenHub: ' + e.message, 'err');
    setSyncState('ehSync', 'error', '✕ failed');
    return null;
  } finally {
    ehBusy = false;
    setBusy(btn, false);
    ehLoad();
  }
}
function ehInstalledText(d) {
  const a = d.app || {};
  return `✓ ${d.upgraded ? 'Updated' : 'Installed'} ${a.name} ${a.version}`
    + ((a.problems || []).length ? ` (${a.problems.length} problem(s) in its manifest)` : '') + (d.note ? '. ' + d.note : '');
}
async function ehInstallFile(btn) {
  const input = $('ehFile');
  const f = input.files && input.files[0];
  if (!f) { ehMsg('Choose a .ehpk file first.', true); return; }
  if (f.size > EH_MAX_MB * 1024 * 1024) { ehMsg(`✕ That file is larger than ${EH_MAX_MB} MB.`, true); return; }
  const bytes = new Uint8Array(await f.arrayBuffer());
  let bin = '';
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  const d = await ehCall('/api/evenhub/install', {ehpk_b64: btoa(bin), filename: f.name}, ehInstalledText, btn);
  if (d) input.value = '';
}
function ehInstallPath(btn) {
  const p = val('ehPath').trim();
  if (!p) { ehMsg('Enter a folder or .ehpk path.', true); return; }
  ehCall('/api/evenhub/install', {path: p}, ehInstalledText, btn);
}
async function ehStoreInfo(btn) {
  const id = val('ehStoreId').trim();
  if (!id) { ehMsg('Enter a store package id.', true); return; }
  const d = await ehCall('/api/evenhub/install', {store_id: id}, () => '', btn);
  if (!d) return;
  const c = d.store || {};
  const el = $('ehMsg');
  el.classList.remove('bad');
  el.innerHTML = `<b>${escapeHtml(c.name)}</b> · ${escapeHtml(c.tagline)} · by ${escapeHtml(c.creator_name)}`
    + `<div class="dim-t">${escapeHtml(d.note)}</div>`;
}
function ehMenu(pid, action, btn) {
  ehCall('/api/evenhub/menu', {package_id: pid, action},
    d => (action === 'add' ? '✓ Added to the menu' : '✓ Removed from the menu') + (d.pushed ? ' on your glasses' : '. ' + (d.note || 'Saved for when your glasses connect.')), btn);
}
function ehLaunch(pid, btn) { ehCall('/api/evenhub/launch', {package_id: pid}, () => '✓ Launched: look at your glasses', btn); }
function ehStop(btn) { ehCall('/api/evenhub/stop', {close_page: true}, d => d.stopped ? '✓ Stopped' : 'Nothing was running', btn); }
async function ehUninstall(pid, name, btn) {
  if (!await uiConfirm(`Uninstall ${name}? Its files and menu entry are removed.`, {ok: 'Uninstall', danger: true})) return;
  ehCall('/api/evenhub/uninstall', {package_id: pid}, d => '✓ Uninstalled' + (d.menu ? '. ' + d.menu : ''), btn);
}
function ehPermText(perms) {
  if (!perms || !perms.length) return 'none';
  return perms.map(p => escapeHtml(p.name) + (p.whitelist && p.whitelist.length ? ` (${p.whitelist.map(escapeHtml).join(', ')})` : '')).join(', ');
}
let EH_MAX_MB = 16;
async function ehLoad() {
  let d;
  try { d = await getJson('/api/evenhub/apps'); }
  catch (e) { if ($('ehApps').querySelector('.skel')) $('ehApps').innerHTML = '<div class="empty">Could not load your apps.</div>'; return; }
  EH_MAX_MB = (d.limits && d.limits.package_mb) || EH_MAX_MB;
  const b = d.bridge || {};
  const menuIds = (d.menu && d.menu.evenhub) || [];
  ehMenuCount = menuIds.length;
  const note = $('menuEhNote');
  if (note) note.textContent = ehMenuCount ? ` (now ${ehMenuCount})` : '';
  const nApps = d.apps.length, nMenu = d.apps.filter(a => a.in_menu).length;
  tileState('evenhub', b.running ? 'Running ' + (b.name || b.package_id) : nApps ? `${nApps} installed` : '');
  let friendly = nApps ? `${nApps} app${nApps === 1 ? '' : 's'} installed, ${nMenu} in your glasses' menu.` : 'No apps installed yet.';
  if (b.running) friendly = `<b>${escapeHtml(b.name || b.package_id)}</b> is running on your glasses. ` + friendly;
  else if (!d.connected) friendly += ' Connect your glasses to launch one.';
  if (!b.browser_available) friendly += ' <span class="bad-t">Apps need Chromium or Google Chrome on this computer.</span>';
  const parts = [d.connected ? 'glasses <b>connected</b>' : 'glasses <b>offline</b>'];
  parts.push(b.browser_available ? `headless browser <b>${escapeHtml(b.browser_available)}</b> found` : '<span class="bad-t">no headless browser found</span>');
  if (b.running) {
    const br = b.browser || {};
    parts.push(`running <b>${escapeHtml(b.name || b.package_id)}</b> (widgetId ${escapeHtml(b.widget_id)})`
      + ` · browser ${br.alive ? '<b>up</b> pid ' + escapeHtml(br.pid) : '<span class="bad-t">not running</span>'}`
      + ` · page ${b.page_created ? 'created' : b.ready ? 'loaded' : 'loading'}` + (br.network ? '' : ' · network blocked'));
  } else {
    parts.push(d.connected ? (b.runtime ? 'bridge idle' : 'bridge starting') : 'bridge off (needs glasses)');
  }
  parts.push(`menu: ${(d.menu && d.menu.builtins) ? d.menu.builtins.length : 'default'} built-in + ${ehMenuCount} EvenHub`);
  $('ehStatus').innerHTML = friendly + `<div class="dev-only hint">${parts.join(' · ')}</div>`;
  const list = $('ehApps');
  if (!d.apps.length) {
    list.innerHTML = '<div class="empty">No apps yet. Install a .ehpk package below.</div>';
  } else {
    list.innerHTML = d.apps.map(a => {
      const running = b.running && b.package_id === a.package_id;
      const pid = escapeHtml(a.package_id);
      return `<div class="ehApp${running ? ' running' : ''}" data-pid="${pid}" data-name="${escapeHtml(a.name)}">
        <div class="ehName">${escapeHtml(a.name)} <span class="ehVer">${escapeHtml(a.version)}</span>
          ${a.in_menu ? '<span class="badge ok plain">In menu</span>' : ''} ${running ? '<span class="badge ack plain">Running</span>' : ''}</div>
        <div class="ehMeta dev-only">${pid} · app id ${escapeHtml(a.app_id)} · menu name "${escapeHtml(a.menu_name)}" · ${escapeHtml(a.kind || '')}</div>
        <div class="ehPerm">Permissions: ${ehPermText(a.permissions)}</div>
        ${(a.problems || []).length ? `<div class="ehProb">Problems in its manifest: ${a.problems.map(escapeHtml).join('; ')}</div>` : ''}
        <div class="row tight">
          ${a.in_menu ? '<button class="secondary small" data-act="menu-remove">Remove from menu</button>'
                      : '<button class="small" data-act="menu-add">Add to menu</button>'}
          <button class="small" data-act="launch" data-needs="glasses">Open now</button>
          <button class="secondary small" data-act="stop" ${running ? '' : 'disabled'}>Stop</button>
          <button class="warn small" data-act="uninstall">Uninstall</button>
        </div>
      </div>`;
    }).join('');
    applyNeeds();
  }
  const log = $('ehLog');
  const calls = d.calls || [];
  log.innerHTML = calls.length ? calls.map(c =>
    `<div>[${escapeHtml(new Date(c.ts * 1000).toLocaleTimeString())}] <span class="m">${escapeHtml(c.method)}</span> ${escapeHtml(c.data)} → ${escapeHtml(c.result)}</div>`).join('')
    : '<div>No bridge calls yet. They appear here while an app runs.</div>';
  log.scrollTop = log.scrollHeight;
}
// Buttons carry the package id in a data attribute (never inside an onclick string).
$('ehApps').addEventListener('click', (e) => {
  const btn = e.target.closest('button[data-act]');
  if (!btn || btn.disabled) return;
  const row = btn.closest('.ehApp');
  const pid = row.dataset.pid, name = row.dataset.name;
  const act = btn.dataset.act;
  if (act === 'menu-add') ehMenu(pid, 'add', btn);
  else if (act === 'menu-remove') ehMenu(pid, 'remove', btn);
  else if (act === 'launch') ehLaunch(pid, btn);
  else if (act === 'stop') ehStop(btn);
  else if (act === 'uninstall') ehUninstall(pid, name, btn);
});

// ───────────────────────── start-up ─────────────────────────
function loadAll() {
  statusLoad(); devLoad(); keysLoad(); loadHubState(); setLoad(); aiLoad(); ltLoad(); mcLoad(); wxLoad(); stLoad(); hlLoad(); wfLoad(); feedLoad(); refreshHNStatus(); ehLoad(); profLoad();
}
renderConn();
loadAll();
connect();
setInterval(refreshHNStatus, 30000);
setInterval(() => { if (!document.hidden) statusLoad(); }, 5000);
setInterval(() => { if ((route === 'home' || route === 'dashboard') && !document.hidden) profLoad(); }, 15000);
setInterval(() => { if (route === 'apps/evenhub' && !document.hidden) ehLoad(); }, 4000);
