"""Weather in the status bar (SID 0x01): live from Open-Meteo or manual values, every 15 min.
Pushed by the sync engine (hub/sync.py 'weather'); the route saves, the loop asks for a refresh."""
import asyncio
import time

import aiohttp
from aiohttp import web

from g2 import dashboard as rdp
from g2 import evenhub as eh
from hub import state, sync, weather
from hub.events import on_event
from hub.glasses import decode_dashboard_ack

WEATHER_DEFAULTS = {'mode': 'auto', 'unit': 'F', 'city': '', 'place': '', 'lat': None, 'lon': None,
                    'manual_temp_f': 72, 'manual_type': 1, 'manual_status': ''}


def weather_settings():
    return {**WEATHER_DEFAULTS, **{k: v for k, v in (state.load_hub_state().get('weather') or {}).items() if k != 'pushed_at'}}


async def push_weather(session, cfg=None):
    """Send weather to the status bar: live from Open-Meteo (mode 'auto') or the manual values.
    Returns (ok, summary)."""
    cfg = cfg or weather_settings()
    context = state.context
    unit = rdp.TEMP_UNIT_FAHRENHEIT if cfg.get('unit', 'F') == 'F' else rdp.TEMP_UNIT_CELSIUS
    if cfg.get('mode') == 'auto':
        if cfg.get('lat') is None:
            loc = await (weather.geocode(cfg['city']) if cfg.get('city') else weather.locate_by_ip())
            cfg.update(lat=loc['lat'], lon=loc['lon'], place=loc['name'])
            cur = weather_settings()        # re-read: the user may have changed it meanwhile
            if cur.get('city') == cfg.get('city') and cur.get('lat') is None:
                state.save_hub_state('weather', {**cur, 'lat': loc['lat'], 'lon': loc['lon'], 'place': loc['name']})
        w = await weather.current(cfg['lat'], cfg['lon'])
        context['weather_now'] = {**w, 'place': cfg.get('place', '')}
        kwargs = dict(weather_type=w['weather_type'], status_string=w['status'], rainfall_icon=w['rain_icon'],
                      rainfall_hint=w['rain_hint'], sunset_select=w['sunset_select'], sunset_hint=w['sunset_hint'])
        temp_c, summary = w['temp_c'], f"{cfg.get('place', '')}: {w['summary']}"
    else:
        temp_c = round((float(cfg.get('manual_temp_f', 72)) - 32) * 5 / 9)
        wtype = int(cfg.get('manual_type', 1))
        status = (cfg.get('manual_status') or weather.WEATHER_TYPES.get(wtype, ''))[:32]
        kwargs = dict(weather_type=wtype, status_string=status)
        summary = f'manual: {cfg.get("manual_temp_f")}°F {status}'
        context['weather_now'] = {'temp_c': temp_c, 'status': status, 'summary': summary}
    magic = session.next_magic()
    payload = rdp.build_weather_push(magic, temp_c, unit=unit, update_time=int(time.time() * 1000), **kwargs)
    raw = await session._send_and_get_payload(rdp.SID_DASHBOARD, eh.FLAG_REQUEST, magic, payload,
                                               session.next_seq(), 'weather push', timeout_s=4.0)
    result = decode_dashboard_ack(raw)
    ok = 'flag=0' in result
    on_event(f'Weather → {summary} ({result})', level='ok' if ok else 'warn')
    return ok, summary


async def api_weather(request):
    """GET → settings + last pushed weather + sync status. POST {mode, city, unit, manual_temp_f,
    manual_type, manual_status, wait?} → save for this pair; the sync engine pushes it. With
    wait (the default for API callers) and connected glasses the push happens now and its result
    comes back ({ok, summary, now}); the web page sends wait=false (debounced, no waiting)."""
    if request.method == 'GET':
        return web.json_response({'settings': weather_settings(), 'now': state.context.get('weather_now'),
                                  'types': weather.WEATHER_TYPES, 'sync': sync.status('weather')})
    data = await request.json()
    cfg = weather_settings()
    if 'city' in data and (data.get('city') or '').strip() != cfg.get('city'):
        cfg.update(city=(data.get('city') or '').strip(), lat=None, lon=None, place='')
    for k in ('mode', 'unit', 'manual_temp_f', 'manual_type', 'manual_status'):
        if k in data:
            cfg[k] = data[k]
    if cfg['mode'] not in ('auto', 'manual') or cfg['unit'] not in ('F', 'C'):
        return web.json_response({'error': 'mode must be auto|manual and unit F|C'}, status=400)
    try:
        if cfg['mode'] == 'auto' and cfg.get('lat') is None:
            loc = await (weather.geocode(cfg['city']) if cfg.get('city') else weather.locate_by_ip())
            cfg.update(lat=loc['lat'], lon=loc['lon'], place=loc['name'])
    except (LookupError, RuntimeError, aiohttp.ClientError) as e:
        return web.json_response({'error': str(e)}, status=502)
    state.save_hub_state('weather', cfg)
    out = await sync.save_and_sync('weather', data.get('wait', True) is not False)
    if out is None:
        return web.json_response({'settings': cfg, 'sync': sync.status('weather'),
                                  **({} if sync.connected() else {'note': 'saved; will push when the glasses connect'})})
    if not out.ok and 'summary' not in out.data:
        return web.json_response({'settings': cfg, 'error': out.message, 'sync': sync.status('weather')}, status=502)
    return web.json_response({'settings': cfg, 'ok': out.ok, 'summary': out.data.get('summary'),
                              'now': state.context.get('weather_now'), 'sync': sync.status('weather')})


async def api_push_weather(request):
    """Manual push kept for compatibility: {temperature (°F), type, status}."""
    data = await request.json()
    session = state.current_session()
    if session is None:
        return web.json_response({'error': 'not connected'}, status=503)
    cfg = {**weather_settings(), 'mode': 'manual', 'manual_temp_f': float(data.get('temperature', 72)),
           'manual_type': int(data.get('type', 1)), 'manual_status': data.get('status', '')}
    async with sync.ENGINE.exclusive():
        ok, summary = await push_weather(session, cfg)
    return web.json_response({'ok': ok, 'summary': summary})


def weather_tick():
    """One refresh: live weather while connected goes through the sync engine (coalesced with an
    edit or the connect-time restore). Returns True if a push was queued."""
    if state.current_session() is not None and weather_settings().get('mode') == 'auto':
        return sync.ENGINE.push_now('weather')
    return False


async def weather_loop():
    """Refresh live weather every 15 minutes while connected (the official app's cadence)."""
    await asyncio.sleep(30)
    while True:
        try:
            weather_tick()
        except Exception as e:
            on_event(f'Weather refresh failed: {e}', level='warn')
        await asyncio.sleep(weather.REFRESH_S)


ROUTES = [
    ('POST', '/api/push_weather', api_push_weather),
    ('GET', '/api/weather', api_weather),
    ('POST', '/api/weather', api_weather),
]
