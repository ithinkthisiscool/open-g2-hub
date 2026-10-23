"""EXPERIMENTAL: user-made widgets (line graph / big-number metric / stock chart) drawn as an EvenHub
image on the glasses. Shares the render + encode + push path of hub.stock_chart (stock_chart.push_image).
UNVERIFIED LIVE on glasses, same caveat as the stock chart.
"""
import csv
import io
import json
import re
from urllib.parse import urlparse

from hub import stock_chart as sc

MIN_POINTS, MAX_POINTS = 2, 500
MAX_BYTES, FETCH_TIMEOUT_S = 256 * 1024, 8
_NUM_SPLIT = re.compile(r'[,\s;]+')


def _fmt(v):
    return f'{v:.0f}' if abs(v) >= 1000 else (f'{v:.2f}'.rstrip('0').rstrip('.') or '0')


def parse_values(text):
    """'1, 2 3\\n4' -> [1.0, 2.0, 3.0, 4.0]. ValueError on junk / non-finite."""
    out = []
    for tok in _NUM_SPLIT.split(str(text or '').strip()):
        if not tok:
            continue
        try:
            f = float(tok)
        except ValueError:
            raise ValueError(f'not a number: {tok[:20]!r}') from None
        if f != f or f in (float('inf'), float('-inf')):
            raise ValueError(f'not a finite number: {tok[:20]!r}')
        out.append(f)
    return out[-MAX_POINTS:]


def _clean_values(values):
    if isinstance(values, str):
        return parse_values(values)
    if not isinstance(values, (list, tuple)):
        raise ValueError('values must be a list of numbers or a string')
    return parse_values(' '.join(str(v) for v in values if not isinstance(v, bool)))


def parse_payload(text):
    """JSON array / {values:[...]} / CSV (last numeric column) -> list of floats. ValueError if none."""
    text = (text or '').strip()
    try:
        data = json.loads(text)
    except ValueError:
        data = None
    if isinstance(data, dict):
        data = data.get('values')
    if isinstance(data, list):
        nums = [v for v in data if isinstance(v, (int, float)) and not isinstance(v, bool)]
        if nums:
            return _clean_values(nums)
    elif data is None:
        vals = []
        for row in csv.reader(io.StringIO(text)):
            for cell in reversed(row):
                try:
                    vals.append(float(cell.strip()))
                    break
                except ValueError:
                    continue
        if vals:
            return _clean_values(vals)
    raise ValueError('no numbers found in the data')


async def fetch_values(url):
    """GET a user-supplied http(s) URL (capped at MAX_BYTES / FETCH_TIMEOUT_S) -> values. Raises
    RuntimeError with a friendly message (never anything else) on any failure. The URL is the user's own
    on a localhost hub; only the scheme is restricted."""
    u = urlparse(str(url or '').strip())
    if u.scheme not in ('http', 'https') or not u.netloc:
        raise ValueError('data URL must start with http:// or https://')
    try:
        import aiohttp
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=FETCH_TIMEOUT_S)) as s:
            async with s.get(u.geturl()) as r:
                if r.status != 200:
                    raise RuntimeError(f'data URL answered HTTP {r.status}')
                body = await r.content.read(MAX_BYTES + 1)
        if len(body) > MAX_BYTES:
            raise RuntimeError('data URL response is too large (256 KB max)')
        return parse_payload(body.decode('utf-8', 'replace'))
    except RuntimeError:
        raise
    except ValueError as e:
        raise RuntimeError(f'data URL: {e}') from None
    except Exception as e:  # noqa: BLE001 - network errors, timeouts
        raise RuntimeError(f'could not fetch the data URL ({type(e).__name__})') from None


def render_graph(title, values, unit='', width=sc.IMG_W, height=sc.IMG_H):
    """Titled line graph (same look as the stock chart): title, last value + unit, min/max. ValueError
    with < 2 numbers; RuntimeError when Pillow is missing."""
    vals = _clean_values(values)
    if len(vals) < MIN_POINTS:
        raise ValueError('need at least 2 numbers')
    Image, ImageDraw, ImageFont = sc._pillow()
    img = Image.new('L', (width, height), 0)
    d = ImageDraw.Draw(img)
    unit = str(unit or '')[:6]
    d.text((4, 2), str(title or 'Graph')[:14], fill=255, font=sc._font(ImageFont, 20))
    d.text((width - 4, 4), f'{_fmt(vals[-1])}{unit}', fill=255, font=sc._font(ImageFont, 13), anchor='ra')
    top, bottom, left, rgt = 30, height - 6, 4, width - 4
    lo, hi = min(vals), max(vals)
    span = (hi - lo) or 1.0
    pts = [(left + (rgt - left) * i / (len(vals) - 1), bottom - (bottom - top) * (v - lo) / span)
           for i, v in enumerate(vals)]
    d.line([(left, bottom), (rgt, bottom)], fill=60)
    d.line([(left, top), (rgt, top)], fill=30)
    d.line(pts, fill=255, width=2, joint='curve')
    ex, ey = pts[-1]
    d.ellipse([ex - 3, ey - 3, ex + 3, ey + 3], fill=255)
    small = sc._font(ImageFont, 10)
    d.text((left, bottom - 1), _fmt(lo), fill=120, font=small, anchor='ls')
    d.text((left, top + 1), _fmt(hi), fill=120, font=small, anchor='la')
    return img


def render_metric(title, value, label='', width=sc.IMG_W, height=sc.IMG_H):
    """Big-number card: small title on top, the value large and centred, small label underneath."""
    value = str(value if value is not None else '').strip()
    if not value:
        raise ValueError('value required')
    Image, ImageDraw, ImageFont = sc._pillow()
    img = Image.new('L', (width, height), 0)
    d = ImageDraw.Draw(img)
    d.text((6, 4), str(title or '')[:24], fill=160, font=sc._font(ImageFont, 16))
    value = value[:12]
    size = 84
    while size > 20:                                    # shrink until it fits the card width
        f = sc._font(ImageFont, size)
        if d.textlength(value, font=f) <= width - 16:
            break
        size -= 6
    d.text((width // 2, height // 2 + 4), value, fill=255, font=sc._font(ImageFont, size), anchor='mm')
    if label:
        d.text((width // 2, height - 6), str(label)[:30], fill=120, font=sc._font(ImageFont, 14), anchor='ms')
    return img


async def push_widget(session, spec, fetch=fetch_values):
    """spec = {type:'graph'|'metric'|'stock', title, values?|url?|unit?, value?|label?, symbol?}.
    Renders and pushes via the stock-chart EvenHub path. Returns a summary dict. ValueError for bad
    input, RuntimeError for no glasses / Pillow missing / fetch or push failure."""
    if not isinstance(spec, dict):
        raise ValueError('spec must be an object')
    kind = str(spec.get('type') or '').lower()
    if kind == 'stock':
        symbol = str(spec.get('symbol') or '').strip()
        if not symbol:
            raise ValueError('symbol required')
        return {'type': 'stock', **await sc.push_stock_chart(session, symbol)}
    if kind not in ('graph', 'metric'):
        raise ValueError('type must be graph, metric or stock')
    if kind == 'metric':
        img = render_metric(spec.get('title'), spec.get('value'), spec.get('label') or '')
        info = {'type': 'metric'}
    else:
        if spec.get('values') not in (None, '', []):
            vals = _clean_values(spec['values'])
        elif spec.get('url'):
            if session is None:
                raise RuntimeError('glasses not connected')
            sc._pillow()
            vals = await fetch(spec['url'])
        else:
            raise ValueError('values or url required')
        img = render_graph(spec.get('title'), vals, spec.get('unit') or '')
        info = {'type': 'graph', 'points': len(vals)}
    if session is None:
        raise RuntimeError('glasses not connected')
    info['bytes'] = await sc.push_image(session, img)
    return info
