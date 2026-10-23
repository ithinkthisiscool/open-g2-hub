"""Paired glasses (device database): list, scan, add, select, rename, forget."""
from aiohttp import web

from g2.session import discover_pairs
from hub import state
from hub.events import notify_state_changed, on_event


def _device_view(d):
    return {k: d[k] for k in ('id', 'pair_id', 'name', 'right_mac', 'left_mac', 'firmware', 'last_seen', 'is_default')}


async def api_devices(request):
    return web.json_response({'devices': [_device_view(d) for d in state.STORE.devices()],
                              'active': state.active_device_id(), 'connected': bool(state.context.get('connected'))})


async def api_devices_scan(request):
    on_event('Scanning for Even G2 glasses (8 s)...', level='info')
    try:
        found = await discover_pairs(timeout=8.0)
    except Exception as e:
        return web.json_response({'error': f'scan failed: {e}'}, status=500)
    known = {d['pair_id']: d['id'] for d in state.STORE.devices()}
    for f in found:
        f['known_id'] = known.get(f['pair_id'])
    on_event(f'Scan found {len(found)} pair(s): {[f["pair_id"] for f in found]} '
             '(connected lenses do not advertise, so the active pair may not appear)', level='ok')
    return web.json_response({'found': found})


async def api_devices_add(request):
    data = await request.json()
    pair_id = str(data.get('pair_id') or '').strip()
    if not pair_id:
        return web.json_response({'error': 'pair_id required'}, status=400)
    dev_id = state.STORE.upsert_device(pair_id, data.get('right_mac'), data.get('left_mac'), data.get('name'))
    on_event(f'Glasses {pair_id} saved', level='ok')
    notify_state_changed('devices')
    return web.json_response({'id': dev_id})


async def api_devices_select(request):
    data = await request.json()
    dev = state.STORE.device(int(data.get('id', 0)))
    if dev is None:
        return web.json_response({'error': 'unknown device'}, status=404)
    state.STORE.set_default(dev['id'])
    state.context['device_id'] = dev['id']
    state.request_reconnect('switch glasses')
    on_event(f'Active glasses → {dev["name"]}; reconnecting', level='ok')
    notify_state_changed('devices')
    notify_state_changed('all')
    return web.json_response({'ok': True})


async def api_devices_rename(request):
    data = await request.json()
    name = str(data.get('name') or '').strip()[:40]
    if not name:
        return web.json_response({'error': 'name required'}, status=400)
    state.STORE.rename(int(data.get('id', 0)), name)
    notify_state_changed('devices')
    return web.json_response({'ok': True})


async def api_devices_forget(request):
    data = await request.json()
    dev_id = int(data.get('id', 0))
    if dev_id == state.active_device_id():
        return web.json_response({'error': 'switch to other glasses before forgetting the active pair'}, status=400)
    state.STORE.forget(dev_id)
    notify_state_changed('devices')
    return web.json_response({'ok': True})


ROUTES = [
    ('GET', '/api/devices', api_devices),
    ('POST', '/api/devices/scan', api_devices_scan),
    ('POST', '/api/devices/add', api_devices_add),
    ('POST', '/api/devices/select', api_devices_select),
    ('POST', '/api/devices/rename', api_devices_rename),
    ('POST', '/api/devices/forget', api_devices_forget),
]
