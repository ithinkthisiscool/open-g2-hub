"""Built-in full-screen apps: Translate / Teleprompter / Navigation (hub/native_apps.py)."""
from aiohttp import web

from hub import nav_routing, state, translate_live


async def _app_call(coro_fn):
    try:
        result = await coro_fn()
    except RuntimeError as e:
        return web.json_response({'error': str(e)}, status=503)
    except (ValueError, KeyError) as e:
        return web.json_response({'error': f'invalid value: {e}'}, status=400)
    body = {'ok': True, **state.APPS_CTL.status()}
    # When the app controller reports a real glasses acknowledgement, tell the truth instead of a
    # blanket ok: acked+ok -> 200; acked+rejected -> 502; silent (no reply) -> 504.
    if isinstance(result, dict) and 'acked' in result:
        body['confirmed'] = bool(result['acked'])
        if result.get('detail'):
            body['detail'] = result['detail']
        if not result.get('ok'):
            body['ok'] = False
            return web.json_response(body, status=502 if result.get('acked') else 504)
    return web.json_response(body)


async def api_app_translate_open(request):
    d = await request.json()
    return await _app_call(lambda: state.APPS_CTL.translate_open(d.get('src') or 'EN', d.get('dst') or 'ES'))


async def api_app_translate_text(request):
    d = await request.json()
    if d.get('src_text') and d.get('dst_text'):      # legacy: both lines supplied, pass straight through
        return await _app_call(lambda: state.APPS_CTL.translate_text(d['src_text'], d['dst_text'],
                                                                     bool(d.get('final', True))))
    text = (d.get('text') or '').strip()
    src, dst = d.get('src') or 'EN', d.get('dst') or 'ES'
    if not text:
        return web.json_response({'error': 'text required'}, status=400)
    try:
        translated = await translate_live.translate(text, src, dst)
    except RuntimeError as e:
        return web.json_response({'error': str(e)}, status=503)

    async def push():
        if state.APPS_CTL.current != 'translate':
            await state.APPS_CTL.translate_open(src, dst)
        return await state.APPS_CTL.translate_text(text, translated, bool(d.get('final', True)))
    resp = await _app_call(push)
    if resp.status != 200:
        return resp
    return web.json_response({'ok': True, 'original': text, 'translated': translated, **state.APPS_CTL.status()})


async def api_app_teleprompter_start(request):
    d = await request.json()
    script = (d.get('script') or '').strip()
    if not script:
        return web.json_response({'error': 'script required'}, status=400)
    return await _app_call(lambda: state.APPS_CTL.teleprompter_start(
        script, mode=int(d.get('mode', 1)), chars_per_line=int(d.get('chars_per_line', 28))))


async def api_app_navigation_start(request):
    nav_routing.clear()
    return await _app_call(state.APPS_CTL.navigation_start)


async def _push_route_step(i):
    """Send step i of the loaded route to the glasses (arrival step also fires the arrive event)."""
    steps = nav_routing.ACTIVE['steps']
    f = nav_routing.step_fields(steps, i)
    await state.APPS_CTL.navigation_step(f.pop('direction'), **f)
    if i == len(steps) - 1:
        await state.APPS_CTL.navigation_event('arrive')
    return steps[i]


async def api_app_navigation_route(request):
    """Real route: geocode `to` (+ `from`), fetch OSRM steps, open Navigation, push step 1.
    No GPS on a PC, so `from` is required (address or "lat,lon"); advance with navigation/step."""
    try:
        d = await request.json()
    except ValueError:
        d = {}
    d = d if isinstance(d, dict) else {}
    to, frm = (d.get('to') or '').strip(), (d.get('from') or '').strip()
    if not to:
        return web.json_response({'error': 'to required'}, status=400)
    if not frm:
        return web.json_response({'error': 'from required: this PC has no GPS, so give a start '
                                            'address or "lat,lon"'}, status=400)
    if state.current_session() is None:             # check first: don't send locations out for nothing
        return web.json_response({'error': 'glasses not connected'}, status=503)
    try:
        flat, flon, fname = await nav_routing.geocode(frm)
        tlat, tlon, tname = await nav_routing.geocode(to)
        steps = await nav_routing.route((flat, flon), (tlat, tlon))
    except nav_routing.RoutingError as e:
        return web.json_response({'error': str(e)}, status=502)
    nav_routing.load(fname, tname, steps)
    first = {}

    async def push():
        await state.APPS_CTL.navigation_start()
        nav_routing.next_index()
        first.update(await _push_route_step(0))
    resp = await _app_call(push)
    if resp.status != 200:
        nav_routing.clear()
        return resp
    return web.json_response({'ok': True, 'from': fname, 'to': tname, 'steps': len(steps), 'first': first,
                              **state.APPS_CTL.status()})


async def api_app_navigation_step(request):
    d = await request.json()
    if nav_routing.ACTIVE and not d.get('direction'):    # route loaded: advance to the next real step
        i = nav_routing.next_index()
        if i is None:
            return web.json_response({'error': 'route finished (last step already sent)'}, status=409)
        out = {}

        async def push():
            out.update(await _push_route_step(i))
        resp = await _app_call(push)
        if resp.status != 200:
            nav_routing.ACTIVE['index'] -= 1             # push failed: stay on the previous step
            return resp
        return web.json_response({'ok': True, 'index': i, 'of': len(nav_routing.ACTIVE['steps']),
                                  'step': out, **state.APPS_CTL.status()})
    fields = {k: d.get(k) or None for k in ('distance', 'road', 'remaining_time', 'remaining_distance', 'eta', 'speed')}
    return await _app_call(lambda: state.APPS_CTL.navigation_step(d.get('direction') or 'straight', **fields))


async def api_app_navigation_event(request):
    d = await request.json()
    if d.get('kind') not in ('recalculating', 'arrive'):
        return web.json_response({'error': 'kind must be recalculating or arrive'}, status=400)
    return await _app_call(lambda: state.APPS_CTL.navigation_event(d['kind']))


async def api_app_stockchart(request):
    """EXPERIMENTAL (EvenHub image, unverified live): draw a stock line chart on the glasses."""
    from hub import stock_chart
    try:
        d = await request.json()
    except ValueError:
        d = {}
    symbol = ((d or {}).get('symbol') or '').strip()
    if not symbol:
        return web.json_response({'error': 'symbol required'}, status=400)
    from hub import stock_quotes
    try:
        stock_quotes.parse_symbols(symbol)
    except ValueError as e:
        return web.json_response({'error': str(e)}, status=400)
    result = {}

    async def push():
        result.update(await stock_chart.push_stock_chart(state.current_session(), symbol))
    resp = await _app_call(push)
    if resp.status != 200:
        return resp
    return web.json_response({'ok': True, 'symbol': result['symbol'], 'points': result['points']})


async def api_app_widget(request):
    """EXPERIMENTAL (EvenHub image, unverified live): draw a custom graph / metric / stock widget."""
    from hub import custom_widget
    try:
        d = await request.json()
    except ValueError:
        d = None
    if not isinstance(d, dict):
        return web.json_response({'error': 'JSON object required'}, status=400)
    result = {}

    async def push():
        result.update(await custom_widget.push_widget(state.current_session(), d))
    resp = await _app_call(push)
    if resp.status != 200:
        return resp
    return web.json_response({'ok': True, **result})


async def api_app_close(request):
    nav_routing.clear()
    return await _app_call(state.APPS_CTL.close)


ROUTES = [
    ('POST', '/api/app/translate/open', api_app_translate_open),
    ('POST', '/api/app/translate/text', api_app_translate_text),
    ('POST', '/api/app/teleprompter/start', api_app_teleprompter_start),
    ('POST', '/api/app/navigation/start', api_app_navigation_start),
    ('POST', '/api/app/navigation/route', api_app_navigation_route),
    ('POST', '/api/app/navigation/step', api_app_navigation_step),
    ('POST', '/api/app/navigation/event', api_app_navigation_event),
    ('POST', '/api/app/stockchart', api_app_stockchart),
    ('POST', '/api/app/widget', api_app_widget),
    ('POST', '/api/app/close', api_app_close),
]
