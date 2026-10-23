"""EvenHub (.ehpk) apps in the hub: install, glasses-menu entries, launch/stop, bridge status.

EXPERIMENTAL: the plugin menu item and the cmd 17 launch are not yet confirmed on the glasses
(docs/evenhub-apps.md section 5). The runtime itself is hub/evenhub_runtime.py.

    GET  /api/evenhub/apps        installed apps, this pair's EvenHub menu entries, bridge status,
                                  recent bridge calls
    POST /api/evenhub/install     {"ehpk_b64": "<base64>", "filename": "x.ehpk"}  upload a package
                                  {"path": "/abs/app-folder" | "/abs/file.ehpk"}  pack/read a local one
                                  {"store_id": "io.github.x.y"}  public store card only (no install:
                                  store packages need a logged-in, signed download)
    POST /api/evenhub/uninstall   {"package_id"}
    POST /api/evenhub/menu        {"package_id", "action": "add" | "remove"}  this pair's menu;
                                  pushed now when connected, else saved and pushed on connect
    POST /api/evenhub/launch      {"package_id"}  run it now (widgetId 10000, no menu needed)
    POST /api/evenhub/stop        {"close_page": true}  stop the running app

Uploads are JSON with base64 (the hub only accepts JSON bodies, see hub/web/middleware.py).

Package contents are untrusted. The runtime bounds sizes and names while unpacking, validates
app.json before writing anything, and the app's code only ever runs inside the headless browser
(AppHost + Browser), never in this Python process. Strings from manifests go back to the page as
JSON and the page escapes them (escapeHtml).

One EvenHubRuntime per glasses connection: attach() registers a connection listener (called by
hub.app at startup). On connect it creates the runtime, fans the session's on_device_event out to
it (keeping any earlier callback), and starts a connection-scoped owner task; when the link
drops the supervisor cancels that task, which stops the app's browser and web host.
"""
import asyncio
import base64
import binascii
import collections
import json
import os
import time
from pathlib import Path

from aiohttp import web

from g2 import evenhub as eh
from g2 import menu as g2menu
from hub import evenhub_runtime as rt
from hub import state, sync
from hub.events import notify_state_changed, on_event
from hub.routes import menu

# The page sends a package as base64 inside JSON: 4/3 of the package plus some slack.
MAX_REQUEST_BYTES = rt.MAX_PACKAGE_BYTES * 4 // 3 + 64 * 1024
CALL_LOG = collections.deque(maxlen=60)      # recent SDK bridge calls, for the UI
_live = {'runtime': None, 'session': None}
_attached = False
_lock = None


def _get_lock():
    global _lock
    if _lock is None:
        _lock = asyncio.Lock()
    return _lock


def registry():
    return menu.evenhub_registry()


def current_runtime():
    """The runtime of the live session, or None (not connected / not started yet)."""
    session = state.current_session()
    if session is None or _live['session'] is not session:
        return None
    return _live['runtime']


def _log(msg):
    on_event(f'EvenHub: {msg}', level='info')


def _short(value, limit=160):
    try:
        text = json.dumps(value, ensure_ascii=False, default=str)
    except (TypeError, ValueError):
        text = repr(value)
    return text if len(text) <= limit else text[:limit] + '…'


def _on_call(app, method, data, result):
    if isinstance(data, dict) and 'imageData' in data:
        data = {**data, 'imageData': f'<{len(data["imageData"] or "")} items>'}
    CALL_LOG.append({'ts': int(time.time()), 'app': app.get('package_id', ''), 'method': method,
                     'data': _short(data), 'result': _short(result, 80)})


# ── one runtime per connection ──────────────────────────────────────────────────────────────
def start_runtime(session):
    """Create the runtime for `session`, hook its device events, and tie its lifetime to the
    connection scope. Returns the runtime."""
    runtime = rt.EvenHubRuntime(
        session, registry(), builtin_ids=menu.saved_builtins() or rt.DEFAULT_BUILTINS, log=_log,
        spawn=lambda coro, name: state.SUP.spawn(coro, name=name, scope='connection'),
        on_call=_on_call)
    prev = session.on_device_event

    def fan_out(event):
        if prev is not None:
            try:
                prev(event)
            except Exception as e:
                on_event(f'device event listener error: {e}', level='warn')
        runtime.on_device_event(event)

    session.on_device_event = fan_out
    _live.update(runtime=runtime, session=session)
    state.SUP.spawn(_own_runtime(runtime, session, fan_out, prev), name='evenhub-runtime', scope='connection')
    return runtime


async def _own_runtime(runtime, session, fan_out, prev):
    """Lives as long as the connection; on cancel (link lost, switch, suspend, shutdown) stops
    the running app and unhooks the device events."""
    try:
        await asyncio.Event().wait()
    finally:
        if getattr(session, 'on_device_event', None) is fan_out:
            session.on_device_event = prev
        if _live['runtime'] is runtime:
            _live.update(runtime=None, session=None)
        await runtime.stop()


def on_connection_change(connected):
    """hub.connection listener."""
    if connected:
        session = state.context.get('session')
        if session is not None:
            start_runtime(session)
        return
    runtime = _live['runtime']
    _live.update(runtime=None, session=None)
    if runtime is not None and runtime.current is not None:     # owner task did not get to it
        state.SUP.spawn(runtime.stop(), name='evenhub-stop', scope='app')


def attach():
    """Register the connection listener once (hub.app calls this at startup)."""
    global _attached
    if _attached:
        return
    from hub import connection
    connection.listeners.append(on_connection_change)
    _attached = True


# ── helpers ────────────────────────────────────────────────────────────────────────────────
def _err(msg, status=400):
    return web.json_response({'error': str(msg)[:400]}, status=status)


async def _body(request):
    try:
        data = await request.json()
    except (ValueError, UnicodeDecodeError):
        return None
    return data if isinstance(data, dict) else None


def _package_id(data):
    pid = data.get('package_id')
    if not isinstance(pid, str) or not rt.SAFE_PACKAGE_ID_RE.match(pid) or len(pid) > 128:
        return None
    return pid


def _menu_ids():
    dev = state.active_device_id()
    return state.STORE.evenhub_menu(dev) if dev is not None else []


def _ensure_saved_builtins():
    """A menu with EvenHub apps is only restored on connect when the pair has a saved built-in
    menu; save the default one when there is none yet. Returns the built-in ids."""
    ids = menu.saved_builtins()
    if ids is None:
        ids = list(rt.DEFAULT_BUILTINS)
        state.save_hub_state('menu', {'items': [{'name': g2menu.BUILTIN_MENU_APPS[i], 'appId': i} for i in ids]})
    return ids


async def _apply_menu(package_ids):
    """Save this pair's EvenHub menu entries; the sync engine pushes the menu (at once when
    connected, waiting for the glasses' answer; on the next connect otherwise).
    Returns (http_status, body)."""
    reg = registry()
    apps = [a for a in (reg.get(p) for p in package_ids) if a is not None]
    builtins = menu.saved_builtins() or list(rt.DEFAULT_BUILTINS)
    err = menu.check_menu(builtins, apps)
    if err:
        return 400, {'error': f'{err}. Remove a built-in app in Widgets → Menu, or another EvenHub app.'}
    dev = state.active_device_id()
    if dev is None:
        return 409, {'error': 'no glasses selected'}
    state.STORE.set_evenhub_menu(dev, [a['package_id'] for a in apps])
    _ensure_saved_builtins()
    notify_state_changed('menu')
    ids = [a['package_id'] for a in apps]
    if state.current_session() is not None:
        out = await sync.sync_now('menu')
        status = 200 if out.ok else (out.data.get('status') or 502)
        return status, {**{k: v for k, v in out.data.items() if k != 'status'}, 'evenhub': ids, 'pushed': out.ok,
                        **({} if out.ok else {'error': out.message, 'note': 'saved; the hub keeps trying'})}
    sync.mark('menu')
    return 200, {'pushed': False, 'evenhub': ids, 'note': 'saved; the menu is pushed when the glasses connect'}


# ── routes ─────────────────────────────────────────────────────────────────────────────────
async def api_apps(request):
    reg = registry()
    in_menu = _menu_ids()
    apps = [{**a, 'in_menu': a['package_id'] in in_menu} for a in reg.list()]
    runtime = current_runtime()
    chrome = rt.find_chromium()
    bridge = {'runtime': runtime is not None,
              'browser_available': os.path.basename(chrome) if chrome else None}
    bridge.update(runtime.status() if runtime is not None else {'running': False})
    builtins = menu.saved_builtins()
    return web.json_response({
        'apps': apps, 'connected': state.current_session() is not None, 'bridge': bridge,
        'menu': {'builtins': builtins, 'evenhub': [p for p in in_menu if reg.get(p)],
                 'max_items': g2menu.MENU_MAX_ITEMS, 'min_items': g2menu.MENU_MIN_ITEMS},
        'calls': list(CALL_LOG)[-30:],
        'limits': {'package_mb': rt.MAX_PACKAGE_BYTES // (1024 * 1024)},
    })


def _store_card(store_id):
    card = rt.store_landing(store_id)
    if not isinstance(card, dict):
        return None
    out = {k: rt.clean_text(card.get(k), 300) for k in ('name', 'tagline', 'creator_name')}
    if isinstance(card.get('icon'), str):
        out['icon_url'] = rt.clean_text(rt.store_asset_url(card['icon']), 500)
    return out


async def api_install(request):
    data = await _body(request)
    if data is None:
        return _err('JSON object expected')
    if data.get('store_id'):
        sid = data['store_id']
        if not isinstance(sid, str) or not rt.SAFE_PACKAGE_ID_RE.match(sid) or len(sid) > 128:
            return _err('store_id must look like com.example.app')
        try:
            card = await asyncio.wait_for(asyncio.to_thread(_store_card, sid), 20)
        except Exception as e:
            return _err(f'store lookup failed: {e}', 502)
        if card is None:
            return _err('not found in the store', 404)
        return web.json_response({'store': card, 'installable': False,
                                  'note': 'Store packages need a logged-in, signed download from the Even app; '
                                          'install a .ehpk you already have, or the app\'s source folder.'})
    if data.get('ehpk_b64') is not None:
        b64 = data['ehpk_b64']
        if not isinstance(b64, str):
            return _err('ehpk_b64 must be a base64 string')
        if len(b64) > MAX_REQUEST_BYTES:
            return _err(f'package larger than {rt.MAX_PACKAGE_BYTES // (1024 * 1024)} MB', 413)
        try:
            blob = base64.b64decode(b64.split(',', 1)[-1], validate=True)
        except (binascii.Error, ValueError):
            return _err('ehpk_b64 is not valid base64')
        if len(blob) > rt.MAX_PACKAGE_BYTES:
            return _err(f'package larger than {rt.MAX_PACKAGE_BYTES // (1024 * 1024)} MB', 413)
        name = rt.clean_text(data.get('filename') or 'upload.ehpk', 120)
        source, label = blob, f'upload: {os.path.basename(name)}'
    elif data.get('path'):
        raw = data['path']
        if not isinstance(raw, str) or '\x00' in raw:
            return _err('path must be a string')
        path = Path(os.path.expanduser(raw))
        if not path.is_absolute():
            return _err('give an absolute path')
        if path.is_dir():
            try:
                manifest, files = await asyncio.to_thread(rt.read_app_folder, path)
                rt.check_manifest(manifest)
                source = await asyncio.to_thread(rt.write_ehpk, manifest, files)     # pack, like `evenhub pack`
            except rt.EhpkError as e:
                return _err(e)
            except OSError as e:
                return _err(f'cannot read {raw}: {e.strerror or e}')
            label = f'folder: {path}'
        elif path.is_file():
            try:
                if path.stat().st_size > rt.MAX_PACKAGE_BYTES:
                    return _err(f'package larger than {rt.MAX_PACKAGE_BYTES // (1024 * 1024)} MB', 413)
                source = await asyncio.to_thread(path.read_bytes)
            except OSError as e:
                return _err(f'cannot read {raw}: {e.strerror or e}')
            label = f'file: {path}'
        else:
            return _err(f'not found: {raw}', 404)
    else:
        return _err('send ehpk_b64, path or store_id')

    async with _get_lock():
        try:
            pkg_id = (await asyncio.to_thread(rt.read_ehpk, source)).manifest.get('package_id')
        except rt.EhpkError as e:
            return _err(e)
        runtime = current_runtime()
        if runtime is not None and runtime.current and runtime.current['app']['package_id'] == pkg_id:
            await runtime.stop()
        old = registry().get(pkg_id) if isinstance(pkg_id, str) and rt.SAFE_PACKAGE_ID_RE.match(pkg_id) else None
        try:
            entry = await asyncio.to_thread(registry().install, source, None, label)
        except rt.EhpkError as e:
            return _err(e)
        except OSError as e:
            return _err(f'install failed: {e.strerror or e}', 500)
        on_event(f'EvenHub app installed: {entry["name"]} {entry["version"]} ({entry["package_id"]}, '
                 f'app id {entry["app_id"]}){" — " + str(len(entry["problems"])) + " manifest problem(s)" if entry["problems"] else ""}',
                 level='ok')
        note = None
        if (old and old.get('menu_name') != entry['menu_name'] and entry['package_id'] in _menu_ids()
                and state.current_session() is not None):
            status, _ = await _apply_menu(_menu_ids())
            note = f'menu re-pushed with the new name ({status})'
    return web.json_response({'ok': True, 'app': {**entry, 'in_menu': entry['package_id'] in _menu_ids()},
                              'upgraded': bool(old), 'note': note})


async def api_uninstall(request):
    data = await _body(request) or {}
    pid = _package_id(data)
    if pid is None:
        return _err('package_id required')
    async with _get_lock():
        if registry().get(pid) is None:
            return _err('not installed', 404)
        runtime = current_runtime()
        if runtime is not None and runtime.current and runtime.current['app']['package_id'] == pid:
            await runtime.stop(close_page=True)
        menu_note = None
        if pid in _menu_ids():
            remaining = [p for p in _menu_ids() if p != pid]
            status, body = await _apply_menu(remaining)
            if status != 200:
                # Keep it out of the saved menu anyway; the next push or connect fixes the glasses.
                dev = state.active_device_id()
                if dev is not None:
                    state.STORE.set_evenhub_menu(dev, remaining)
                menu_note = f'removed from the saved menu; push failed: {body.get("error")}'
            else:
                menu_note = 'removed from the menu' + (' on the glasses' if body.get('pushed') else ' (saved)')
        ok = await asyncio.to_thread(registry().uninstall, pid)
    on_event(f'EvenHub app uninstalled: {pid}', level='ok')
    return web.json_response({'ok': ok, 'menu': menu_note})


async def api_menu(request):
    data = await _body(request) or {}
    pid = _package_id(data)
    action = data.get('action')
    if pid is None or action not in ('add', 'remove'):
        return _err('package_id and action ("add" or "remove") required')
    async with _get_lock():
        current = [p for p in _menu_ids() if registry().get(p) is not None]
        if action == 'add':
            if registry().get(pid) is None:
                return _err('not installed', 404)
            new = current if pid in current else current + [pid]
        else:
            new = [p for p in current if p != pid]
        status, body = await _apply_menu(new)
    return web.json_response(body, status=status)


async def api_launch(request):
    data = await _body(request) or {}
    pid = _package_id(data)
    if pid is None:
        return _err('package_id required')
    if registry().get(pid) is None:
        return _err('not installed', 404)
    runtime = current_runtime()
    if runtime is None:
        return _err('not connected', 503)
    try:
        url = await state.SUP.run_connection_job(
            runtime.launch(pid, launch_source='appMenu', widget_id=eh.DEFAULT_WIDGET_ID), name='evenhub-launch')
    except KeyError:
        return _err('not installed', 404)
    except Exception as e:
        return _err(f'launch failed: {e}', 500)
    if url is None:
        return _err('glasses disconnected', 503)
    return web.json_response({'ok': True, 'bridge': runtime.status()})


async def api_stop(request):
    data = await _body(request) or {}
    runtime = current_runtime()
    if runtime is None or runtime.current is None:
        return web.json_response({'ok': True, 'stopped': False})
    stopped = await runtime.stop(close_page=data.get('close_page', True) is not False)
    return web.json_response({'ok': True, 'stopped': stopped})


ROUTES = [
    ('GET', '/api/evenhub/apps', api_apps),
    ('POST', '/api/evenhub/install', api_install),
    ('POST', '/api/evenhub/uninstall', api_uninstall),
    ('POST', '/api/evenhub/menu', api_menu),
    ('POST', '/api/evenhub/launch', api_launch),
    ('POST', '/api/evenhub/stop', api_stop),
]
