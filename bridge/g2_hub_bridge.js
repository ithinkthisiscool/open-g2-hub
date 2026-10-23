// g2_hub_bridge.js - Part of G2 Hub. MIT licence (see the repository's LICENSE).
//
// A small bridge library for EvenHub-style plugins (web pages that drive the G2 glasses).
// It is written from G2 Hub's own runtimes only: the PC hub (g2-hub/hub/evenhub_runtime.py,
// EvenHubBridge + SHIM_JS) and the phone app (g2-mobile/lib/services/evenhub_service.dart,
// EvenHubBridge + shimJs). Both runtimes inject a shim before the page's scripts run that
// provides
//
//   window.flutter_inappwebview.callHandler(handler, ...args) -> Promise<result>
//
// and push host -> page messages by calling window._listenEvenAppMessage(message).
//
// Wire contract (what our runtimes accept and send):
//   page -> host   callHandler('evenAppMessage', JSON.stringify(
//                      {type: 'call_even_app_method', method: <name>, data: {...}}))
//                  The promise resolves with the method's result (see METHODS below).
//   host -> page   _listenEvenAppMessage({type: 'listen_even_app_data', method, data}) with
//                  method one of 'evenHubEvent', 'evenAppLaunchSource', 'deviceStatusChanged',
//                  'appLocationChanged' (phone only).
//
// No build step and no dependencies: import it as an ES module next to your page,
//
//   import { connect, EventType } from './g2_hub_bridge.js';
//   const hub = await connect();
//   await hub.createPage({ texts: [textBox({ id: 1, name: 'msg', content: 'Hi', capture: true })] });
//   hub.on('list', (e) => ...);
//
// The full API is documented in g2-hub/docs/evenhub-apps.md ("Plugins written against
// G2 Hub's bridge").

const W = typeof window !== 'undefined' ? window : globalThis;

/** Event types carried in list / text / sys events (g2 library: g2.widgets.evenhub EVENT_*). */
export const EventType = Object.freeze({
  CLICK: 0,
  SCROLL_TOP: 1,
  SCROLL_BOTTOM: 2,
  DOUBLE_CLICK: 3,
  FOREGROUND_ENTER: 4,
  FOREGROUND_EXIT: 5,
  ABNORMAL_EXIT: 6,
  SYSTEM_EXIT: 7,
  IMU_DATA: 8,
  LONG_PRESS: 9,
  LONG_PRESS_RELEASE: 10,
});

/** createPage() results (the runtime's createStartUpPageContainer return codes). */
export const CreateResult = Object.freeze({ OK: 0, INVALID: 1, OVERSIZE: 2, OUT_OF_MEMORY: 3 });

/** setImage() results (the runtime's updateImageRawData return codes). */
export const ImageResult = Object.freeze({ OK: 0, EXCEPTION: 1, SIZE_INVALID: 2, SEND_FAILED: 3 });

/** The display the containers are laid out on, in pixels. */
export const SCREEN = Object.freeze({ width: 576, height: 288 });

/** Every method name our runtimes answer (hub: EvenHubBridge.m_<name>; phone: _dispatch). */
export const METHODS = Object.freeze([
  'getUserInfo',
  'getGlassesInfo',
  'setLocalStorage',
  'getLocalStorage',
  'getAppLocation',
  'startAppLocationUpdates',
  'stopAppLocationUpdates',
  'pickImageFromAlbum',
  'captureImageFromCamera',
  'createStartUpPageContainer',
  'rebuildPageContainer',
  'textContainerUpgrade',
  'updateImageRawData',
  'audioControl',
  'imuControl',
  'shutDownPageContainer',
]);

// ── container helpers: friendly names -> the JSON fields the runtimes encode ─────────────────
function geometry(o) {
  const g = {
    xPosition: o.x ?? 0,
    yPosition: o.y ?? 0,
    width: o.width ?? 0,
    height: o.height ?? 0,
    containerID: o.id,
    containerName: o.name ?? '',
  };
  if (o.zOrder !== undefined) g.zOrderIndex = o.zOrder;
  return g;
}

function border(o, g) {
  if (o.borderWidth !== undefined) g.borderWidth = o.borderWidth;
  if (o.borderColor !== undefined) g.borderColor = o.borderColor;
  if (o.borderRadius !== undefined) g.borderRadius = o.borderRadius;
  if (o.padding !== undefined) g.paddingLength = o.padding;
  return g;
}

/**
 * A text container. {id, name, x, y, width, height, content, capture, color (0-4), zOrder,
 * borderWidth, borderColor, borderRadius, padding}. `capture: true` makes it the container that
 * receives the glasses' input (exactly one container per page must capture).
 */
export function textBox(o) {
  const t = border(o, geometry(o));
  t.content = o.content ?? '';
  t.isEventCapture = o.capture ? 1 : 0;
  if (o.color !== undefined) t.textColor = o.color;
  return t;
}

/**
 * A list container. {id, name, x, y, width, height, items: [string], capture, itemWidth,
 * selectBorder (default true), zOrder, border...}. Picking an item fires a 'list' event.
 */
export function listBox(o) {
  const items = (o.items ?? []).map(String);
  const l = border(o, geometry(o));
  l.itemContainer = { itemCount: items.length, itemName: items, isItemSelectBorderEn: o.selectBorder === false ? 0 : 1 };
  if (o.itemWidth !== undefined) l.itemContainer.itemWidth = o.itemWidth;
  l.isEventCapture = o.capture ? 1 : 0;
  return l;
}

/** An image container {id, name, x, y, width, height, zOrder}; fill it with setImage(). */
export function imageBox(o) {
  return geometry(o);
}

/** Page JSON {texts, lists, images, menu: [{id, name}]} -> the runtimes' page object. */
export function pageObject(p) {
  const texts = p.texts ?? [];
  const lists = p.lists ?? [];
  const images = p.images ?? [];
  const page = {
    containerTotalNum: texts.length + lists.length + images.length,
    textObject: texts,
    listObject: lists,
    imageObject: images,
  };
  if (p.menu && p.menu.length) {
    page.menuObject = { menuItems: p.menu.map((m) => ({ itemID: m.id, itemName: m.name })) };
  }
  return page;
}

// ── events ───────────────────────────────────────────────────────────────────────────────────
// evenHubEvent data is {type: 'listEvent'|'textEvent'|'sysEvent'|'menuItemClickEvent', jsonData}.
// It is delivered as one normalised object, to 'event' listeners and to the kind's listeners:
//   list  {kind, containerID, containerName, index, item, eventType}
//   text  {kind, containerID, containerName, eventType}
//   sys   {kind, eventType, eventSource, imu?: {x, y, z}, exitReason?}
//   menu  {kind, itemID}
const KINDS = { listEvent: 'list', textEvent: 'text', sysEvent: 'sys', menuItemClickEvent: 'menu' };

export function normaliseEvent(data) {
  const d = (data && data.jsonData) || {};
  const kind = KINDS[data && data.type] || 'unknown';
  if (kind === 'list') {
    return { kind, containerID: d.containerID, containerName: d.containerName,
             index: d.currentSelectItemIndex ?? 0, item: d.currentSelectItemName ?? '', eventType: d.eventType ?? 0 };
  }
  if (kind === 'text') return { kind, containerID: d.containerID, containerName: d.containerName, eventType: d.eventType ?? 0 };
  if (kind === 'sys') {
    const e = { kind, eventType: d.eventType ?? 0, eventSource: d.eventSource ?? 0 };
    if (d.imuData) e.imu = d.imuData;
    if (d.systemExitReasonCode) e.exitReason = d.systemExitReasonCode;
    return e;
  }
  if (kind === 'menu') return { kind, itemID: d.itemID };
  return { kind, raw: data };
}

// ── the bridge ───────────────────────────────────────────────────────────────────────────────
export class G2HubBridge {
  constructor(callHandler) {
    this._callHandler = callHandler;
    this._listeners = new Map();      // name -> Set<fn>
    this.launchSource = null;         // last evenAppLaunchSource (replayed to late listeners)
    this.deviceStatus = null;         // last deviceStatusChanged
  }

  /** Raw call: any method in METHODS with its JSON data. Resolves with the runtime's result. */
  call(method, data = {}) {
    const msg = JSON.stringify({ type: 'call_even_app_method', method, data });
    return Promise.resolve(this._callHandler('evenAppMessage', msg));
  }

  // pages ---------------------------------------------------------------------------------------
  /** Create the app's page (once per launch). Resolves with a CreateResult code. */
  createPage(page) { return this.call('createStartUpPageContainer', pageObject(page)); }

  /** Replace the whole page (creates it if needed). Resolves true/false. */
  rebuildPage(page) { return this.call('rebuildPageContainer', pageObject(page)); }

  /**
   * Change a text container's content. opts: {offset, length, color}. With no offset/length the
   * whole text is replaced. Resolves true/false.
   */
  setText(id, name, content, opts = {}) {
    const d = { containerID: id, containerName: name, content: String(content) };
    if (opts.offset !== undefined) d.contentOffset = opts.offset;
    if (opts.length !== undefined) d.contentLength = opts.length;
    if (opts.color !== undefined) d.textColor = opts.color;
    return this.call('textContainerUpgrade', d);
  }

  /**
   * Fill an image container. image: a base64 string or data: URL (PNG/JPEG/BMP/GIF), or an array
   * / Uint8Array of bytes (an encoded image, 8-bit grey or packed 4-bit grey at the box's size).
   * Resolves with an ImageResult code.
   */
  setImage(id, image) {
    const imageData = typeof image === 'string' ? image : Array.from(image);
    return this.call('updateImageRawData', { containerID: id, imageData });
  }

  /** Close the page. ask=true lets the glasses ask the user first. Resolves true/false. */
  closePage({ ask = false } = {}) { return this.call('shutDownPageContainer', { exitMode: ask ? 1 : 0 }); }

  // sensors -------------------------------------------------------------------------------------
  /** Glasses microphone on/off. Resolves true when the glasses acknowledged. */
  microphone(on) { return this.call('audioControl', { isOpen: !!on, source: 'glasses' }); }

  /** IMU reports on/off; they arrive as 'sys' events with eventType IMU_DATA and `imu`. */
  imu(on, { reportFrq = 500 } = {}) { return this.call('imuControl', { iMUReportEn: !!on, reportFrq }); }

  // storage, host info --------------------------------------------------------------------------
  /** Per-app key/value storage kept by the host (strings). */
  getItem(key) { return this.call('getLocalStorage', { key: String(key) }); }
  setItem(key, value) { return this.call('setLocalStorage', { key: String(key), value: String(value) }); }

  getUser() { return this.call('getUserInfo'); }
  getGlasses() { return this.call('getGlassesInfo'); }

  /** Phone runtime only (apps with the "location" permission); the PC hub answers null/false. */
  getLocation({ accuracy = 'medium', timeoutMs = 10000 } = {}) { return this.call('getAppLocation', { accuracy, timeoutMs }); }
  startLocation({ accuracy = 'medium', distanceFilter = 0 } = {}) {
    return this.call('startAppLocationUpdates', { accuracy, distanceFilter });
  }
  stopLocation() { return this.call('stopAppLocationUpdates'); }

  // events --------------------------------------------------------------------------------------
  /**
   * Subscribe. name: 'event' (every glasses event), 'list', 'text', 'sys', 'menu', 'launch'
   * (launch source string), 'status' (device status), 'location' (phone fixes), 'message'
   * (every raw host message). Returns an unsubscribe function.
   */
  on(name, fn) {
    if (!this._listeners.has(name)) this._listeners.set(name, new Set());
    this._listeners.get(name).add(fn);
    if (name === 'launch' && this.launchSource !== null) queueMicrotask(() => fn(this.launchSource));
    if (name === 'status' && this.deviceStatus !== null) queueMicrotask(() => fn(this.deviceStatus));
    return () => this._listeners.get(name).delete(fn);
  }

  _emit(name, value) {
    for (const fn of this._listeners.get(name) ?? []) {
      try { fn(value); } catch (e) { console.error('[g2_hub_bridge]', name, e); }
    }
  }

  /** Host -> page entry point (installed as window._listenEvenAppMessage). */
  receive(message) {
    const msg = typeof message === 'string' ? JSON.parse(message) : message;
    if (!msg || typeof msg !== 'object') return;
    this._emit('message', msg);
    if (msg.method === 'evenHubEvent') {
      const e = normaliseEvent(msg.data);
      this._emit('event', e);
      this._emit(e.kind, e);
    } else if (msg.method === 'evenAppLaunchSource') {
      this.launchSource = (msg.data && msg.data.launchSource) ?? null;
      this._emit('launch', this.launchSource);
    } else if (msg.method === 'deviceStatusChanged') {
      this.deviceStatus = msg.data;
      this._emit('status', msg.data);
    } else if (msg.method === 'appLocationChanged') {
      this._emit('location', msg.data);
    }
  }
}

let shared = null;
const early = [];   // host messages that arrived before the bridge existed

function attach(host) {
  if (!shared) {
    shared = new G2HubBridge((...args) => host.callHandler(...args));
    W._listenEvenAppMessage = (m) => shared.receive(m);
    while (early.length) shared.receive(early.shift());
  }
  return shared;
}

/**
 * Wait for the host shim and return the page's bridge (one per page). Rejects after timeoutMs
 * when the page is not running inside a G2 Hub runtime.
 */
export function connect({ timeoutMs = 10000 } = {}) {
  if (shared) return Promise.resolve(shared);
  const start = Date.now();
  return new Promise((resolve, reject) => {
    (function check() {
      const host = W.flutter_inappwebview;
      if (host && typeof host.callHandler === 'function') {
        resolve(attach(host));
      } else if (Date.now() - start > timeoutMs) {
        reject(new Error('g2_hub_bridge: no host (window.flutter_inappwebview.callHandler) found'));
      } else {
        setTimeout(check, 20);
      }
    })();
  });
}

// Install the host -> page entry point right away, so messages pushed before connect() resolves
// (the launch source, the device status) are kept; the bridge remembers the last launch source
// and device status and replays them to listeners added later.
if (typeof W._listenEvenAppMessage !== 'function') {
  W._listenEvenAppMessage = (m) => { if (shared) shared.receive(m); else early.push(m); };
}
