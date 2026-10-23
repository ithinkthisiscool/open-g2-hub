"""The hub's one sync engine (hub/sync_engine.py) and its sections.

Every data-editing route saves its change for the active pair and calls mark() (or sync_now()
when an API caller wants the glasses' answer); the engine pushes. Nothing in the web UI sends data
to the glasses by hand any more. The same engine does:

* the connect-time restore (hub.connection.apply_profile attaches it): settings, layout, weather,
  menu, tasks, calendar, news, stocks, health, in that order, 2 s after the link is up;
* the periodic refreshes (weather and calendar every 15 min, news every 30 min, ICS sync, stocks):
  the loops only call push_now(), so a refresh that coincides with an edit or the restore is one
  push, not two;
* profile switches (hub.profiles marks the sections the profile changed).

Push functions read the CURRENT saved data when they run (never a copy taken when the edit was
made), so a coalesced push always carries the latest edit. They never save over the user's data
(push_menu / push_quicklist are called with save=False).
"""
import json
import logging

from hub import state
from hub.events import broadcast
from hub.sync_engine import SyncEngine, SyncOutcome

log = logging.getLogger('g2hub.sync')

RESTORE_DELAY_S = 2.0        # the old apply_profile waited 2 s after connect before pushing

# (key, label, restore). Registration order = push priority = the reconnect restore order.
SECTIONS = (
    ('settings', 'Display and behaviour', True),
    ('layout', 'Dashboard layout', True),
    ('weather', 'Weather', True),
    ('menu', 'Menu', True),
    ('tasks', 'Tasks', True),
    ('calendar', 'Calendar', True),
    ('news', 'News', True),
    ('stocks', 'Stocks', True),
    ('health', 'Health', True),
    ('notifications', 'Notifications', False),   # the connect sequence already enables them
)
RESTORE_ORDER = tuple(k for k, _, r in SECTIONS if r)

# Saved config section (hub.db / profiles) -> sync section.
CONFIG_TO_SECTION = {'settings': 'settings', 'layout': 'layout', 'weather': 'weather', 'menu': 'menu',
                     'evenhub_menu': 'menu', 'quicklist': 'tasks', 'calendar': 'calendar',
                     'calendar_sync': 'calendar', 'news': 'news', 'stocks': 'stocks', 'health': 'health',
                     'notifications': 'notifications'}


def _broadcast(engine):
    broadcast(json.dumps({'type': 'sync', **engine.snapshot()}, default=str))


ENGINE = SyncEngine(on_change=_broadcast,
                    spawn=lambda coro, name: state.SUP.spawn(coro, name=name, scope='connection'),
                    ctx_provider=state.current_session)


def mark(*keys, now=False):
    """Data behind these sections (or saved config keys) changed. now=True skips the debounce."""
    for k in keys:
        sec = CONFIG_TO_SECTION.get(k, k)
        if now:
            ENGINE.push_now(sec)
        else:
            ENGINE.mark_dirty(sec)


async def sync_now(key, timeout=30.0):
    return await ENGINE.sync_now(CONFIG_TO_SECTION.get(key, key), timeout=timeout)


def status(key):
    """The per-card status for a route response: {status, text, last_synced, error}."""
    s = ENGINE.section(key)
    if s is None:
        return None
    return {'section': key, 'status': s.status, 'text': ENGINE.describe(key), 'last_synced': s.last_synced,
            'error': s.last_error, 'connected': ENGINE.connected}


def connected():
    return state.current_session() is not None


async def save_and_sync(key, wait):
    """After a route saved `key`: wait=True and connected -> push now and return the outcome;
    otherwise queue it (debounced) and return None."""
    if wait and connected():
        return await sync_now(key)
    mark(key)
    return None


# ── section push functions (ctx = the live GlassesSession) ──────────────────────────────────
def _dev():
    return state.active_device_id()


async def push_settings(session):
    from g2 import settings as gset
    from hub.glasses import send_framed
    from hub.routes.settings import apply_settings
    dev = _dev()
    saved = state.STORE.get(dev, 'settings') if dev is not None else None
    if not saved:
        return SyncOutcome.nothing('glasses defaults')
    await apply_settings(session, saved)
    await send_framed(session, gset.SID, gset.build_read_settings(session.next_magic()))   # fresh read-back
    return SyncOutcome.success('settings sent', {'saved': saved})


async def push_layout(session):
    """Widget order on the dashboard. The PC hub has no layout editor yet: this section only sends
    a layout saved in the 'layout' config section ({custom: true, order: [...], h24, celsius})."""
    from g2 import dashboard as rdp
    from g2 import evenhub as eh
    from hub.glasses import decode_dashboard_ack
    cfg = state.load_hub_state().get('layout') or {}
    order = [int(x) for x in cfg.get('order') or [] if str(x).isdigit()]
    if not cfg.get('custom') or not order:
        return SyncOutcome.nothing('built-in layout')
    magic = session.next_magic()
    payload = rdp.build_dashboard_layout(magic, order, half_day_format=0 if cfg.get('h24') else 1,
                                         temperature_unit=rdp.TEMP_UNIT_CELSIUS if cfg.get('celsius', True)
                                         else rdp.TEMP_UNIT_FAHRENHEIT)
    raw = await session._send_and_get_payload(rdp.SID_DASHBOARD, eh.FLAG_REQUEST, magic, payload,
                                               session.next_seq(), 'dashboard layout', timeout_s=4.0)
    ack = decode_dashboard_ack(raw)
    return SyncOutcome('flag=0' in ack, f'layout: {ack}')


async def push_weather(session):
    from hub.routes import weather
    ok, summary = await weather.push_weather(session)
    data = {'ok': ok, 'summary': summary, 'now': state.context.get('weather_now')}
    return SyncOutcome(ok, summary if ok else f'{summary}: no ack', data)


async def push_menu(session):
    from hub.routes import menu
    builtins = menu.saved_builtins()
    if builtins is None:
        if not menu.saved_evenhub():
            return SyncOutcome.nothing('default menu')
        from hub import evenhub_runtime as rt
        builtins = list(rt.DEFAULT_BUILTINS)
    status_code, body = await menu.push_menu([{'appId': i} for i in builtins], save=False)
    data = {**body, 'status': status_code}
    if status_code == 200:
        return SyncOutcome.success('menu sent', data)
    # 400 = the saved menu is invalid: retrying cannot help until it is edited.
    return SyncOutcome.failed(body.get('error', f'HTTP {status_code}'), data, retry=status_code != 400)


async def push_tasks(session):
    from hub.routes import tasks
    task_list = tasks.load_tasks()
    if not task_list:
        return SyncOutcome.nothing('no tasks')
    status_code, body = await tasks.push_quicklist(task_list, save=False)
    data = {**body, 'status': status_code}
    if status_code != 200:
        return SyncOutcome.failed(body.get('error', f'HTTP {status_code}'), data, retry=status_code != 400)
    acked = body.get('acked') or str(body.get('display_enable', '')).endswith('flag=0')
    return SyncOutcome(bool(acked), f'{len(task_list)} task(s) sent' + ('' if acked else ' (no ack)'), data)


async def push_calendar(session):
    from hub.routes import calendar as cal
    saved = state.load_hub_state()
    st = cal.calendar_state()
    if not st['events'] and 'calendar' not in saved and not cal.sync_config()['url']:
        return SyncOutcome.nothing('no calendar')
    ok, n = await cal.push_calendar(session, st)
    return SyncOutcome(ok, f'{n} event(s)' + ('' if ok else ' (not all acked)'), {'ok': ok, 'sent': n})


async def push_news(session):
    from hub.routes import news
    stories = await news.load_stories()
    if not stories:
        return SyncOutcome.nothing('no stories yet')
    status_code, body = await news.push_news(news.articles(stories))
    if status_code != 200:
        return SyncOutcome.failed(body.get('error', f'HTTP {status_code}'), body)
    if body.get('all_acked'):
        await news.mark_pushed()
    return SyncOutcome(bool(body.get('all_acked')), f'{len(stories)} stories' + ('' if body.get('all_acked') else ' (not all acked)'), body)


async def push_stocks(session):
    from hub.routes import stocks
    cfg = stocks.stock_settings()
    if not cfg.get('show'):
        return SyncOutcome.nothing('not shown on the glasses')
    quotes, errors = await stocks.quotes_for_push(cfg['symbols'])
    if not quotes:
        return SyncOutcome.failed('no quotes: ' + '; '.join(errors) if errors else 'no quotes')
    ok, results = await stocks.push_stocks(session, quotes)
    return SyncOutcome(ok, f'{len(quotes)} quote(s)' + ('' if ok else ' (not all acked)'),
                       {'quotes': quotes, 'errors': errors, 'pushed': ok, 'acks': results})


async def push_health(session):
    from hub.routes import health
    saved = state.load_hub_state().get('health') or {}
    if not saved.get('show'):
        return SyncOutcome.nothing('not shown on the glasses')
    values = {k: saved[k] for k in health.FIELDS if saved.get(k) not in (None, '')}
    if not values:
        return SyncOutcome.nothing('no values')
    ok, detail = await health.push_health(session, values, saved.get('show_card', True))
    return SyncOutcome(ok, '; '.join(detail), {'saved': values, 'ok': ok, 'detail': detail})


async def push_notifications(session):
    from hub.routes import notify
    cfg = state.load_hub_state().get('notifications') or {}
    await notify.setup(session, int(cfg.get('disp_time', 5)))
    return SyncOutcome.success('notifications on')


PUSH = {'settings': push_settings, 'layout': push_layout, 'weather': push_weather, 'menu': push_menu,
        'tasks': push_tasks, 'calendar': push_calendar, 'news': push_news, 'stocks': push_stocks,
        'health': push_health, 'notifications': push_notifications}


def register_all(engine=ENGINE):
    for key, label, restore in SECTIONS:
        engine.register(key, PUSH[key], label=label, restore=restore)


register_all()
