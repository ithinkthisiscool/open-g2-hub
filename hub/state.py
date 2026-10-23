"""Shared hub state: the live session context, the database, the task supervisor, the native-app
controller, and the per-pair config helpers every feature module uses.

Modules import this module (`from hub import state`) and read `state.STORE`, `state.context`
etc. at call time, so init_store() can point the hub at another database (tests do).
"""
import asyncio
import json
import os
import time

import aiohttp

from g2.session import RIGHT_MAC, LEFT_MAC
from hub import auth, paths, store
from hub.events import on_event
from hub.native_apps import NativeApps
from hub.supervisor import Supervisor

RECONNECT_DELAY_S = 5
HN_CACHE_MAX_AGE_S = 1800  # 30 minutes between auto-refreshes

# The live session and per-connection values. Keys: session, connected, port, device_id,
# weather_now, ai_phase, ai_turn, ai_hb_task, glasses_status, keepalive_echo,
# reconnect_requested, foreground_app, battery_warned.
context = {'session': None, 'connected': False, 'port': 8766}

# Seed for an empty database. With G2_RIGHT_MAC / G2_LEFT_MAC (and optionally G2_PAIR_ID) set,
# that pair; otherwise a placeholder with no lens addresses, which the connection loop fills in
# from discovery (connection.adopt_discovered_pair) or the user fills in with Scan in the web UI.
SEED_PAIR_ID = os.environ.get('G2_PAIR_ID') or ('env' if RIGHT_MAC and LEFT_MAC else 'unset')
SEED_PAIR = (SEED_PAIR_ID, RIGHT_MAC, LEFT_MAC)

STORE = None                 # hub.store.Store, set by init_store()
NEWS_CACHE_FILE = None       # set by init_store()
TOKEN = None                 # API token (hub.auth), set by the app at startup

SUP = Supervisor(report=lambda msg, level='err': on_event(msg, level=level))


def current_session():
    """The live GlassesSession, or None when not connected."""
    session = context.get('session')
    if session is None or not context.get('connected'):
        return None
    return session


APPS_CTL = NativeApps(current_session, lambda msg, level='info': on_event(msg, level=level),
                      spawn=lambda coro, name: SUP.spawn(coro, name=name, scope='connection'))


def init_store(db_file=None, news_cache_file=None):
    """Open the database (default: the XDG data dir) and set the news cache location."""
    global STORE, NEWS_CACHE_FILE
    db_file = str(db_file or paths.db_path())
    paths.ensure_dir(os.path.dirname(db_file))
    STORE = store.Store(db_file)
    NEWS_CACHE_FILE = str(news_cache_file or (os.path.join(os.path.dirname(STORE.path), paths.NEWS_CACHE_NAME)))
    return STORE


def init_devices():
    """Make sure the database has a default pair, importing the older JSON state into it once."""
    dev = STORE.default_device()
    if dev is None:
        dev_id = STORE.upsert_device(*SEED_PAIR)
        dev = STORE.device(dev_id)
    imported = STORE.import_legacy(dev['id'], str(paths.legacy_hub_state_file()), str(paths.legacy_ai_log_file()))
    if imported:
        print(f'Imported into device {dev["pair_id"]}: {imported}', flush=True)
        on_event(f'Imported into device {dev["pair_id"]}: {imported}')
    context['device_id'] = dev['id']
    return dev


def active_device_id():
    return context.get('device_id')


def load_hub_state():
    """All saved sections (calendar, quicklist, menu, even_ai, ...) for the active glasses."""
    dev = active_device_id()
    if dev is None:
        return {}
    return {k: v for k, v in STORE.all_config(dev).items() if not k.startswith('_')}


def save_hub_state(key, data):
    dev = active_device_id()
    if dev is not None:
        STORE.set(dev, key, {**data, 'pushed_at': int(time.time())})


# ── news cache (hn_cache.json in the data dir) ──────────────────────────────────────────────
def load_news_cache():
    try:
        with open(NEWS_CACHE_FILE) as f:
            return json.load(f)
    except Exception:
        return None


def save_news_cache(data):
    """Atomic write (temp file + rename) so a crash never leaves a half-written cache."""
    try:
        tmp = f'{NEWS_CACHE_FILE}.tmp'
        with open(tmp, 'w') as f:
            json.dump(data, f)
        os.replace(tmp, NEWS_CACHE_FILE)
    except Exception as e:
        on_event(f'news cache save error: {e}', level='warn')


async def aload_news_cache():
    return await asyncio.to_thread(load_news_cache)


async def asave_news_cache(data):
    await asyncio.to_thread(save_news_cache, data)


# ── calling the hub's own API (assistant tools, low-battery notification) ───────────────────
async def post_self(path, body):
    """Call one of the hub's own API endpoints (same code path as the web UI)."""
    port = context.get('port', 8766)
    headers = {auth.HEADER: TOKEN} if TOKEN else {}
    async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=90)) as sess:
        async with sess.post(f'http://localhost:{port}{path}', json=body, headers=headers) as r:
            return r.status, await r.json(content_type=None)


# ── waking the connection loop (glasses switch, keep-alive watchdog, suspend, adapter power) ──
WAKE = asyncio.Event()     # set whenever the connection loop should re-check its conditions


def request_reconnect(reason=''):
    """Ask the connection loop to drop the current link (if any) and connect again."""
    context['reconnect_requested'] = True
    if reason:
        context['reconnect_reason'] = reason
    WAKE.set()
