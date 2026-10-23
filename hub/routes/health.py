"""Health card (SID 0x0e): EXPERIMENTAL, never seen on the glasses. The hub pushes a snapshot of
today's numbers (the glasses have no sensors the dashboard reads). Values are typed in by hand."""
from aiohttp import web

from g2 import dashboard as rdp
from g2 import evenhub as eh
from g2 import health
from hub import state, sync
from hub.events import on_event
from hub.glasses import decode_dashboard_ack

FIELDS = {          # name: (min, max, integer?)
    'steps': (0, 200000, True), 'step_goal': (0, 200000, True),
    'calories': (0, 20000, True), 'calorie_goal': (0, 20000, True),
    'sleep_minutes': (0, 1440, True), 'sleep': (0, 100, False),
    'heart_rate': (20, 250, True), 'heart_rate_avg': (20, 250, True),
    'spo2': (50, 100, True), 'spo2_avg': (50, 100, True),
}
DEFAULTS = {'steps': 6500, 'step_goal': 10000, 'calories': 1800, 'calorie_goal': 2200,
            'sleep_minutes': 450, 'sleep': 82, 'heart_rate': 68, 'heart_rate_avg': 64,
            'spo2': 98, 'spo2_avg': 97, 'show_card': True, 'show': False}


def health_settings():
    saved = state.load_hub_state().get('health') or {}
    return {**DEFAULTS, **{k: v for k, v in saved.items() if k in DEFAULTS}}


def clean(data):
    """Validate the posted values. Blank = leave that metric out. Raises ValueError."""
    out = {}
    for name, (lo, hi, integer) in FIELDS.items():
        v = data.get(name)
        if v in (None, ''):
            continue
        try:
            v = int(v) if integer else float(v)
        except (TypeError, ValueError):
            raise ValueError(f'{name} must be a number')
        if not lo <= v <= hi:
            raise ValueError(f'{name} must be {lo}-{hi}')
        out[name] = v
    if not out:
        raise ValueError('enter at least one value')
    return out


async def push_health(session, values, show_card=True):
    """Optionally enable the health card in the dashboard order, then send the snapshot.
    Returns (ok, detail)."""
    detail = []
    if show_card:
        magic = session.next_magic()
        raw = await session._send_and_get_payload(rdp.SID_DASHBOARD, eh.FLAG_REQUEST, magic,
                                                   rdp.build_display_enable(magic, [rdp.WIDGET_HEALTH]),
                                                   session.next_seq(), 'health card enable', timeout_s=4.0)
        detail.append(f'card enable: {decode_dashboard_ack(raw)}')
    magic = session.next_magic()
    raw = await session._send_and_get_payload(health.SID, eh.FLAG_REQUEST, magic,
                                               health.build_dashboard_snapshot(magic, **values),
                                               session.next_seq(), 'health snapshot', timeout_s=4.0)
    if raw is None:
        detail.append('snapshot: no ack (health acks are unconfirmed; check the glasses)')
        ok = False
    else:
        d = health.decode(raw)
        detail.append(f'snapshot: reply {d.get("name")} error={d.get("error", 0)}')
        ok = not d.get('error')
    on_event('Health → ' + '; '.join(detail), level='ok' if ok else 'warn')
    return ok, detail


async def api_health(request):
    """GET → saved values + sync status. POST {steps, step_goal, ..., show_card, show?, wait?} →
    save for this pair. show (default true for API callers: "put these on the glasses") lets the
    sync engine push them after the edit and on every connect; the page sends its checkbox."""
    if request.method == 'GET':
        return web.json_response({'settings': health_settings(), 'fields': list(FIELDS), 'sync': sync.status('health')})
    data = await request.json()
    try:
        values = clean(data)
    except ValueError as e:
        return web.json_response({'error': str(e)}, status=400)
    show_card = bool(data.get('show_card', True))
    show = bool(data.get('show', True))
    state.save_hub_state('health', {**values, 'show_card': show_card, 'show': show})
    if not show:
        return web.json_response({'saved': values, 'note': 'saved; not shown on the glasses', 'sync': sync.status('health')})
    out = await sync.save_and_sync('health', data.get('wait', True) is not False)
    if out is None:
        return web.json_response({'saved': values, 'sync': sync.status('health'),
                                  **({} if sync.connected() else {'note': 'saved; glasses not connected'})})
    return web.json_response({'saved': values, 'ok': out.ok, 'detail': out.data.get('detail', [out.message]),
                              'sync': sync.status('health')})


ROUTES = [
    ('GET', '/api/health', api_health),
    ('POST', '/api/health', api_health),
]
