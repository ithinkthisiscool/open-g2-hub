"""Stock quotes for the dashboard's stock card, from Yahoo Finance's public chart endpoint
(no API key). One request per symbol returns price, previous close, day range, volume, name and
the intraday points used for the card's mini chart.

The endpoint is unofficial: treat failures per symbol as normal and keep the others."""
import asyncio
import re

import aiohttp

from g2 import stocks

CHART_URL = 'https://query1.finance.yahoo.com/v8/finance/chart/{symbol}?range=1d&interval=30m'
HEADERS = {'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) g2hub'}
SYMBOL_RE = re.compile(r'^[A-Za-z0-9.\-^=]{1,15}$')
MAX_SYMBOLS = 8
MAX_POINTS = 24
TIMEOUT_S = 10

US_EXCHANGES = {'NMS', 'NGM', 'NCM', 'NYQ', 'ASE', 'PCX', 'BTS', 'NAS', 'NYS', 'PNK', 'OQB', 'OQX'}


def parse_symbols(text):
    """'aapl, MSFT tsla' -> ['AAPL', 'MSFT', 'TSLA']. Raises ValueError on a bad or too-long list."""
    items = [s.strip().upper() for s in re.split(r'[\s,;]+', text or '') if s.strip()]
    items = list(dict.fromkeys(items))
    if not items:
        raise ValueError('enter at least one symbol')
    if len(items) > MAX_SYMBOLS:
        raise ValueError(f'at most {MAX_SYMBOLS} symbols')
    bad = [s for s in items if not SYMBOL_RE.match(s)]
    if bad:
        raise ValueError(f'invalid symbol(s): {", ".join(bad)}')
    return items


def quote_from_chart(symbol, chart):
    """Turn one chart API result into a dict for g2.stocks.build_stock()."""
    result = (chart.get('chart') or {}).get('result') or []
    if not result:
        err = ((chart.get('chart') or {}).get('error') or {}).get('description') or 'no data'
        raise LookupError(f'{symbol}: {err}')
    meta = result[0].get('meta') or {}
    price = meta.get('regularMarketPrice')
    prev = meta.get('chartPreviousClose') or meta.get('previousClose')
    if price is None:
        raise LookupError(f'{symbol}: no price')
    change = (price - prev) / prev * 100 if prev else 0.0
    quote = ((result[0].get('indicators') or {}).get('quote') or [{}])[0]
    closes = [c for c in (quote.get('close') or []) if c is not None][-MAX_POINTS:]
    opens = [o for o in (quote.get('open') or []) if o is not None]
    exchange = meta.get('exchangeName') or ''
    q = {
        'code': symbol,
        'market_suffix': 'US' if exchange in US_EXCHANGES else exchange[:8],
        'name': meta.get('longName') or meta.get('shortName') or symbol,
        'price': float(price),
        'change_percent': round(change, 2),
        'trend': stocks.TREND_UP if change > 0 else stocks.TREND_DOWN if change < 0 else stocks.TREND_FLAT,
        'day_high': meta.get('regularMarketDayHigh'),
        'day_low': meta.get('regularMarketDayLow'),
        'open': opens[0] if opens else None,
        'volume': meta.get('regularMarketVolume'),
        'dark_price': prev,
    }
    if closes:
        q['points'] = closes
    return {k: v for k, v in q.items() if v is not None}


async def fetch_quote(http, symbol):
    async with http.get(CHART_URL.format(symbol=symbol), headers=HEADERS) as r:
        if r.status == 404:
            raise LookupError(f'{symbol}: unknown symbol')
        r.raise_for_status()
        return quote_from_chart(symbol, await r.json(content_type=None))


async def fetch_quotes(symbols):
    """Returns (quotes, errors): quotes in the order given, errors as 'SYMBOL: reason' strings."""
    timeout = aiohttp.ClientTimeout(total=TIMEOUT_S)
    async with aiohttp.ClientSession(timeout=timeout) as http:
        results = await asyncio.gather(*(fetch_quote(http, s) for s in symbols), return_exceptions=True)
    quotes, errors = [], []
    for sym, res in zip(symbols, results):
        if isinstance(res, Exception):
            errors.append(str(res) if isinstance(res, LookupError) else f'{sym}: {type(res).__name__}')
        else:
            quotes.append(res)
    return quotes, errors


def summary(q):
    return f"{q['code']} {q['price']:.2f} ({q['change_percent']:+.2f}%)"
