"""Calendar widget (SID 0x01): per-pair event list. The sync engine (hub/sync.py 'calendar')
pushes it after an edit, on connect, every 15 min and when the subscribed ICS feed changes."""
import asyncio
import time

from aiohttp import web

from g2 import dashboard as rdp
from g2 import evenhub as eh
from hub import calendar_events, calendar_sync, state, sync
from hub.events import on_event
from hub.glasses import decode_dashboard_ack


SYNC_SECTION = 'calendar_sync'     # {url, enabled, events, last_try, last_ok, note}


def sync_config():
    c = state.load_hub_state().get(SYNC_SECTION) or {}
    return {'url': c.get('url') or '', 'enabled': bool(c.get('enabled')), 'events': c.get('events') or [],
            'last_try': c.get('last_try'), 'last_ok': c.get('last_ok'), 'note': c.get('note') or ''}


def sync_status():
    """What the UI shows (never the cached events)."""
    c = sync_config()
    return {'url': c['url'], 'enabled': c['enabled'], 'last_try': c['last_try'], 'last_ok': c['last_ok'],
            'note': c['note'], 'count': len(c['events'])}


def manual_events():
    return calendar_events.migrate(state.load_hub_state().get('calendar') or {})


def calendar_state():
    """Manual events + (when enabled) the synced ICS events, each tagged with its 'source'."""
    st = state.load_hub_state().get('calendar') or {}
    manual = [{**e, 'source': 'manual'} for e in calendar_events.migrate(st)
              if not str(e.get('id', '')).startswith(calendar_sync.ID_PREFIX)]
    cfg = sync_config()
    synced = cfg['events'] if cfg['enabled'] and cfg['url'] else []
    return {'events': sorted(manual + synced, key=lambda e: int(e['start'])), 'h24': bool(st.get('h24', False))}


def _view(extra=None):
    return {**calendar_state(), 'sync': sync_status(), 'glasses_sync': sync.status('calendar'), **(extra or {})}


async def _synced_view(wait):
    """Queue the calendar push (wait + connected: push now) and build the response."""
    out = await sync.save_and_sync('calendar', wait)
    if out is None:
        return web.json_response(_view({} if sync.connected() else {'note': 'saved; will push when the glasses connect'}))
    return web.json_response(_view({'ok': out.ok, 'sent': out.data.get('sent', 0),
                                    **({} if out.ok else {'error': out.message})}))


async def push_calendar(session, cal=None):
    """Send every upcoming event (earliest first, max 8) with its display time. Returns (ok, n)."""
    cal = cal or calendar_state()
    schedules = calendar_events.to_schedules(cal['events'], h24=cal['h24'])
    # One event per message (scheduleTotal = n, scheduleNum = i), like the official app.
    items = list(enumerate(schedules)) or [(0, None)]
    ok = True
    for i, sched in items:
        magic = session.next_magic()
        payload = rdp.build_calendar_event_push(magic, sched, len(schedules), i,
                                                authority=1 if not schedules else 0)
        raw = await session._send_and_get_payload(rdp.SID_DASHBOARD, eh.FLAG_REQUEST, magic, payload,
                                                   session.next_seq(), f'calendar {i + 1}/{len(schedules)}')
        ok = ok and 'flag=0' in decode_dashboard_ack(raw)
    on_event(f'Calendar → {len(schedules)} event(s): ' +
             '; '.join(f'{t} {ts}' for t, _, ts, _ in schedules[:3]) + (' (all acked)' if ok else ' (some not acked)'),
             level='ok' if ok else 'warn')
    return ok, len(schedules)


def save_calendar(events, h24):
    now = time.time()
    keep = [e for e in events if int(e['end']) > now - 86400
            and not str(e.get('id', '')).startswith(calendar_sync.ID_PREFIX)]   # synced events are not stored as manual   # drop events that ended over a day ago
    state.save_hub_state('calendar', {'events': sorted(keep, key=lambda e: int(e['start'])), 'h24': bool(h24)})


async def api_calendar(request):
    """GET → {events, h24, sync, glasses_sync}. POST {events: [...], h24, wait?} → validate, save
    for this pair; the sync engine pushes it (wait, the API default: now, with the result)."""
    if request.method == 'GET':
        return web.json_response(_view())
    data = await request.json()
    try:
        events = [calendar_events.normalize(e) for e in data.get('events', [])]
    except (ValueError, TypeError) as e:
        return web.json_response({'error': str(e)}, status=400)
    h24 = data.get('h24', calendar_state()['h24'])
    save_calendar(events, h24)
    return await _synced_view(data.get('wait', True) is not False)


async def run_sync(fetch=None):
    """Fetch the configured ICS feed and store the result. Returns True when the synced events changed.
    A failed fetch keeps the previous events (a flaky network must not empty the glasses)."""
    cfg = sync_config()
    if not cfg['url'] or not cfg['enabled']:
        return False
    events, note = await calendar_sync.sync_ics(cfg['url'], fetch=fetch)
    now = int(time.time())
    if note:
        on_event(f'Calendar sync: {note}', level='warn')
        new = {**cfg, 'last_try': now, 'note': note}
    else:
        on_event(f'Calendar sync: {len(events)} event(s) in the next few days', level='ok')
        new = {**cfg, 'events': events, 'last_try': now, 'last_ok': now, 'note': ''}
    state.save_hub_state(SYNC_SECTION, new)
    return not note and events != cfg['events']


async def api_calendar_sync(request):
    """POST {url, enabled} → save the ICS subscription for this pair, fetch it now, push if connected."""
    data = await request.json()
    cfg = sync_config()
    try:
        url = calendar_sync.normalize_url(data['url']) if 'url' in data else cfg['url']
    except ValueError as e:
        return web.json_response({'error': str(e)}, status=400)
    enabled = bool(data.get('enabled', cfg['enabled'])) and bool(url)
    keep = url == cfg['url']
    state.save_hub_state(SYNC_SECTION, {**cfg, 'url': url, 'enabled': enabled,
                                         'events': cfg['events'] if keep else [],
                                         'last_ok': cfg['last_ok'] if keep else None,
                                         'note': cfg['note'] if keep else ''})
    if enabled:
        await run_sync()
    if not sync.connected() and sync_config()['note']:
        sync.mark('calendar')
        return web.json_response(_view({'note': sync_config()['note']}))
    return await _synced_view(data.get('wait', True) is not False)


async def calendar_sync_loop():
    """Every 15 minutes re-fetch the subscribed ICS feed (when enabled for the active pair) and push
    only if the events changed. The push is connection-scoped, like calendar_loop."""
    await asyncio.sleep(20)
    while True:
        try:
            if await run_sync():
                sync.ENGINE.push_now('calendar')      # offline: queued for the next connect
        except asyncio.CancelledError:
            raise
        except Exception as e:
            on_event(f'Calendar sync loop error: {e}', level='warn')
        await asyncio.sleep(calendar_events.REFRESH_S)


async def api_push_calendar(request):
    """Compatibility: {title, location, minutes, duration} adds one event and pushes."""
    data = await request.json()
    try:
        ev = calendar_events.normalize({'title': data.get('title'), 'location': data.get('location'),
                                        'minutes_from_now': data.get('minutes', 5),
                                        'duration_min': data.get('duration', 60)})
    except (ValueError, TypeError) as e:
        return web.json_response({'error': str(e)}, status=400)
    st = calendar_state()
    save_calendar(st['events'] + [ev], st['h24'])
    if not sync.connected():
        sync.mark('calendar')
        return web.json_response({'error': 'not connected'}, status=503)
    out = await sync.sync_now('calendar')
    return web.json_response({'ok': out.ok, 'sent': out.data.get('sent', 0)})


def calendar_tick():
    """One 15-minute refresh (ended events drop off, tomorrow's become today's): a sync-engine
    push while connected. Returns True if a push was queued."""
    if state.current_session() is not None and calendar_state()['events']:
        return sync.ENGINE.push_now('calendar')
    return False


async def calendar_loop():
    """Every 15 minutes (the app's cadence) re-send the calendar through the sync engine."""
    await asyncio.sleep(45)
    while True:
        try:
            calendar_tick()
        except Exception as e:
            on_event(f'Calendar refresh failed: {e}', level='warn')
        await asyncio.sleep(calendar_events.REFRESH_S)


ROUTES = [
    ('POST', '/api/push_calendar', api_push_calendar),
    ('GET', '/api/calendar', api_calendar),
    ('POST', '/api/calendar', api_calendar),
    ('POST', '/api/calendar/sync', api_calendar_sync),
]
