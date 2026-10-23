"""Stock card on the native dashboard (SID 0x01): EXPERIMENTAL, not yet seen on the glasses.
Quotes come from hub/stock_quotes.py; one stock per message, each acked before the next.
Saved per pair as {symbols, show}; with show on, the sync engine ('stocks') pushes fresh quotes
after an edit, on connect and every 15 minutes."""
import asyncio
import time

import aiohttp
from aiohttp import web

from g2 import evenhub as eh
from g2 import stocks
from hub import state, stock_quotes, sync
from hub.events import on_event
from hub.glasses import decode_dashboard_ack

DEFAULTS = {'symbols': ['AAPL', 'MSFT', 'NVDA'], 'show': False}
REFRESH_S = 15 * 60
QUOTE_REUSE_S = 120        # quotes fetched by the route are reused by the push right after it


def stock_settings():
    saved = state.load_hub_state().get('stocks') or {}
    return {**DEFAULTS, **{k: v for k, v in saved.items() if k in DEFAULTS}}


async def push_stocks(session, quotes):
    """Send each quote as its own message (stockNum 0..n-1 of stockTotal n). Returns a list of
    per-symbol ack strings."""
    results = []
    for i, q in enumerate(quotes):
        magic = session.next_magic()
        payload = stocks.build_stock_push(magic, q, stock_total=len(quotes), stock_num=i)
        raw = await session._send_and_get_payload(stocks.SID, eh.FLAG_REQUEST, magic, payload,
                                                   session.next_seq(), f'stock push {q["code"]}', timeout_s=4.0)
        results.append(f'{q["code"]}: {decode_dashboard_ack(raw)}')
    ok = all('flag=0' in r for r in results)
    on_event(f'Stocks → {", ".join(stock_quotes.summary(q) for q in quotes)} ({"all acked" if ok else "; ".join(results)})',
             level='ok' if ok else 'warn')
    return ok, results


async def quotes_for_push(symbols):
    """(quotes, errors): the route's quotes when fresh and for the same symbols, else fetched."""
    last = state.context.get('stocks_last') or {}
    if (last.get('symbols') == list(symbols) and last.get('quotes')
            and time.time() - last.get('at', 0) < QUOTE_REUSE_S):
        return last['quotes'], last.get('errors', [])
    quotes, errors = await stock_quotes.fetch_quotes(symbols)
    state.context['stocks_last'] = {'quotes': quotes, 'errors': errors, 'symbols': list(symbols), 'at': time.time()}
    return quotes, errors


def stocks_tick():
    """15-minute refresh while connected and shown. Returns True if a push was queued."""
    if state.current_session() is not None and stock_settings().get('show'):
        return sync.ENGINE.push_now('stocks')
    return False


async def stocks_loop():
    await asyncio.sleep(90)
    while True:
        try:
            stocks_tick()
        except Exception as e:
            on_event(f'Stocks refresh failed: {e}', level='warn')
        await asyncio.sleep(REFRESH_S)


async def api_stocks(request):
    """GET → saved settings + last quotes + sync status. POST {symbols: "AAPL, MSFT", show?, push?,
    wait?} → fetch quotes and save the symbols. `show` turns the card on the glasses on/off; without
    it, push (default true) means "show them" (the old behaviour) and push=false is a preview only.
    Shown: the sync engine pushes them (wait, the API default, + connected: now, with the acks)."""
    ctx = state.context
    if request.method == 'GET':
        return web.json_response({'settings': stock_settings(), 'last': ctx.get('stocks_last'),
                                  'max_symbols': stock_quotes.MAX_SYMBOLS, 'sync': sync.status('stocks')})
    data = await request.json()
    raw_symbols = data.get('symbols')
    if isinstance(raw_symbols, list):
        raw_symbols = ' '.join(str(s) for s in raw_symbols)
    try:
        symbols = stock_quotes.parse_symbols(raw_symbols)
    except ValueError as e:
        return web.json_response({'error': str(e)}, status=400)
    prev = stock_settings()
    show = bool(data['show']) if 'show' in data else (True if data.get('push', True) else prev['show'])
    state.save_hub_state('stocks', {'symbols': symbols, 'show': show})
    try:
        quotes, errors = await stock_quotes.fetch_quotes(symbols)
    except aiohttp.ClientError as e:
        return web.json_response({'error': f'quote fetch failed: {e}', 'sync': sync.status('stocks')}, status=502)
    ctx['stocks_last'] = {'quotes': quotes, 'errors': errors, 'symbols': symbols, 'at': time.time()}
    body = {'quotes': quotes, 'errors': errors, 'settings': stock_settings()}
    if not quotes:
        return web.json_response({**body, 'error': 'no quotes fetched', 'sync': sync.status('stocks')}, status=502)
    if not show:
        return web.json_response({**body, 'sync': sync.status('stocks')})
    out = await sync.save_and_sync('stocks', data.get('wait', True) is not False)
    if out is None:
        note = {} if sync.connected() else {'note': 'glasses not connected; fetched now, shown when they connect'}
        return web.json_response({**body, **note, 'sync': sync.status('stocks')})
    return web.json_response({**body, 'pushed': out.ok, 'acks': out.data.get('acks', []), 'sync': sync.status('stocks')})


ROUTES = [
    ('GET', '/api/stocks', api_stocks),
    ('POST', '/api/stocks', api_stocks),
]
