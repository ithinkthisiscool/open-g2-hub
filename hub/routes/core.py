"""The page, the live WebSocket, and the read-only status endpoints."""
import os
import time

from aiohttp import WSMsgType, web

from hub import connection, state
from hub.events import clients, history, to_json
from hub.routes import diagnostics
from hub.version import __version__
from hub.web import page as webpage


async def index(request):
    # The token goes into a <meta> tag; only same-origin script can read the response.
    html = webpage.render_index(state.TOKEN, __version__)
    return web.Response(text=html, content_type='text/html', headers={'Cache-Control': 'no-store'})


async def static_asset(request):
    """/static/{app.js,theme.js,style.css}: read from hub/web/static at request time. no-store
    keeps edits visible on reload (small local files; the ?v= on the references is a second guard)."""
    name = request.match_info['name']
    ctype = webpage.ASSET_TYPES.get(name)
    if ctype is None:
        raise web.HTTPNotFound()
    return web.Response(text=webpage.read_static(name), content_type=ctype, charset='utf-8',
                        headers={'Cache-Control': 'no-store'})


async def websocket_handler(request):
    ws = web.WebSocketResponse()
    await ws.prepare(request)
    clients.add(ws)
    try:
        for event in list(history):
            await ws.send_str(to_json(event))
        async for msg in ws:
            if msg.type == WSMsgType.ERROR:
                break
    except Exception:
        pass
    finally:
        clients.discard(ws)
    return ws


RECONNECT_WINDOW_S = 120     # how long after a lost link the state reads 'reconnecting'


def _mark_connected(connected):
    if connected:
        state.context['ever_connected'] = True
    elif state.context.get('ever_connected'):
        state.context['link_lost_at'] = time.monotonic()


connection.listeners.append(_mark_connected)     # so a short-lived link still counts


def ble_disabled():
    """True when the hub runs as a web UI only (G2HUB_NO_BLE=1, see hub/app.py)."""
    return os.environ.get('G2HUB_NO_BLE', '').strip().lower() in ('1', 'true', 'yes')


def link_state(now=None):
    """(link, paused_reasons) for the web UI and the desktop app.

    link: 'connected'; 'disabled' (G2HUB_NO_BLE: this hub never connects); 'paused' (system
    suspend or Bluetooth adapter off, see hub/power.py; the reasons are in the list);
    'reconnecting' (the link was lost less than RECONNECT_WINDOW_S ago and the connection loop is
    trying again); 'searching' (not connected, looking for the glasses: never connected since the
    hub started, or lost for longer, e.g. glasses in their case)."""
    ctx = state.context
    if ctx.get('connected'):
        ctx['ever_connected'] = True
        return 'connected', []
    if ble_disabled():
        return 'disabled', []
    reasons = sorted(ctx.get('paused') or ())
    if reasons:
        return 'paused', reasons
    lost = ctx.get('link_lost_at')
    now = time.monotonic() if now is None else now
    if lost is not None and now - lost < RECONNECT_WINDOW_S:
        return 'reconnecting', []
    return 'searching', []


async def api_status(request):
    """{connected, link, paused, version, cause, hint}: see link_state(). cause/hint (see
    hub.routes.diagnostics.classify) say why the glasses are not connected; null when they are."""
    link, reasons = link_state()
    cause, hint = diagnostics.classify(link, reasons, diagnostics.has_adapter(), diagnostics.pair_saved())
    return web.json_response({'connected': bool(state.context.get('connected')), 'link': link, 'paused': reasons,
                              'version': diagnostics.__version__, 'cause': cause, 'hint': hint})


async def api_hub_state(request):
    """Return the last-pushed state for calendar and quicklist (mirrors what's on the glasses)."""
    st = state.load_hub_state()
    now = int(time.time())
    result = {}
    for key, val in st.items():
        pushed_at = val.get('pushed_at', 0)
        result[key] = {**val, 'pushed_ago_s': now - pushed_at, 'pushed_ago_min': (now - pushed_at) // 60}
    return web.json_response(result)


ROUTES = [
    ('GET', '/', index),
    ('GET', '/static/{name}', static_asset),
    ('GET', '/ws', websocket_handler),
    ('GET', '/api/status', api_status),
    ('GET', '/api/hub_state', api_hub_state),
    *diagnostics.ROUTES,       # /api/doctor, /api/diagnostics (registered here: hub.app lists core)
]
