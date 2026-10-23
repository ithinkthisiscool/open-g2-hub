"""EXPERIMENTAL: draw a stock line chart as an EvenHub image on the glasses.

The native dashboard only shows fixed numeric widgets; an EvenHub image container is how a custom
bitmap gets onto the display. UNVERIFIED LIVE: the page layout and fragment protocol come from
g2.evenhub (itself marked UNTESTED LIVE), and the firmware's CompressMode / pixel packing are
inferred (raw, 4 bpp grey, high nibble = left pixel, the same format hub.evenhub_runtime uses).

Display: the G2 screen is 576x288; the chart uses a 288x144 container centred on it (the SDK's
image containers are limited to roughly 288x144). Price history comes from the same Yahoo chart
endpoint as the stock card (hub.stock_quotes: up to MAX_POINTS intraday closes, 30 minute bars);
only that short window is available, so the chart is intraday and has at most 24 points.
"""
import asyncio

from g2 import evenhub as eh

from hub import evenhub_runtime as rt

IMG_W, IMG_H = 288, 144
IMG_X, IMG_Y = (576 - IMG_W) // 2, (288 - IMG_H) // 2
CONTAINER_ID, CONTAINER_NAME = 1, 'stockchart'
PILLOW_HINT = "Pillow is required for the stock chart: pip install -e '.[images]'"
MIN_POINTS = 2


def _pillow():
    try:
        from PIL import Image, ImageDraw, ImageFont
    except ImportError as e:
        raise RuntimeError(PILLOW_HINT) from e
    return Image, ImageDraw, ImageFont


def _font(ImageFont, size):
    try:
        return ImageFont.load_default(size=size)
    except TypeError:                       # Pillow < 10.1 has a fixed-size default
        return ImageFont.load_default()


def render_chart(symbol, prices, width=IMG_W, height=IMG_H):
    """Line chart of `prices` (oldest first) as an 8-bit grey ('L') Pillow image, green-screen style
    (bright on black). Header: symbol, last price, % change vs the first point. Raises ValueError
    with fewer than 2 prices, RuntimeError when Pillow is missing."""
    prices = [float(p) for p in prices if p is not None]
    if len(prices) < MIN_POINTS:
        raise ValueError('need at least 2 price points')
    Image, ImageDraw, ImageFont = _pillow()
    img = Image.new('L', (width, height), 0)
    d = ImageDraw.Draw(img)
    last, first = prices[-1], prices[0]
    pct = (last - first) / first * 100 if first else 0.0
    big, small = _font(ImageFont, 20), _font(ImageFont, 13)
    d.text((4, 2), str(symbol).upper()[:10], fill=255, font=big)
    right = f'{last:.2f}  {pct:+.2f}%'
    d.text((width - 4, 4), right, fill=255, font=small, anchor='ra')
    top, bottom, left, rgt = 30, height - 6, 4, width - 4
    lo, hi = min(prices), max(prices)
    span = (hi - lo) or 1.0
    pts = []
    for i, p in enumerate(prices):
        x = left + (rgt - left) * i / (len(prices) - 1)
        y = bottom - (bottom - top) * (p - lo) / span
        pts.append((x, y))
    d.line([(left, bottom), (rgt, bottom)], fill=60)                    # baseline
    d.line([(left, top), (rgt, top)], fill=30)
    d.line(pts, fill=255, width=2, joint='curve')
    ex, ey = pts[-1]
    d.ellipse([ex - 3, ey - 3, ex + 3, ey + 3], fill=255)
    d.text((left, bottom - 1), f'{lo:.2f}', fill=120, font=_font(ImageFont, 10), anchor='ls')
    d.text((left, top + 1), f'{hi:.2f}', fill=120, font=_font(ImageFont, 10), anchor='la')
    return img


def encode_image(img):
    """Grey Pillow image -> packed 4 bpp bytes (high nibble = left pixel), the raw format
    hub.evenhub_runtime sends."""
    w, h = img.size
    return eh.pack_4bpp([p >> 4 for p in img.convert('L').getdata()], w, h)


def build_chart_messages(img, magic_fn, session_id=1, fragment_bytes=rt.IMAGE_FRAGMENT_BYTES):
    """-> (create_page_payload, [image_fragment_payloads]) as EvenHub protobufs (not framed)."""
    w, h = img.size
    page = eh.build_create_image_page(magic_fn(), CONTAINER_NAME, CONTAINER_ID, IMG_X, IMG_Y, w, h)
    data = eh.encode_bmp_4bpp(encode_image(img), w, h)   # the firmware decodes a 4-bit BMP file
    frags = []
    for i, off in enumerate(range(0, len(data), fragment_bytes)):
        frags.append(eh.build_image_raw_data(magic_fn(), CONTAINER_ID, CONTAINER_NAME, len(data), i,
                                             data[off:off + fragment_bytes],
                                             map_session_id=session_id, compress_mode=0))
    return page, frags


async def fetch_prices(symbol):
    """-> (prices, quote). Reuses hub.stock_quotes (Yahoo chart: intraday closes + live price)."""
    from hub import stock_quotes
    sym = stock_quotes.parse_symbols(symbol)[0]
    quotes, errors = await stock_quotes.fetch_quotes([sym])
    if not quotes:
        raise RuntimeError(errors[0] if errors else f'{sym}: no data')
    q = quotes[0]
    prices = list(q.get('points') or [])
    if q.get('price') is not None and (not prices or prices[-1] != q['price']):
        prices.append(q['price'])
    return prices, q


async def push_stock_chart(session, symbol, fetch=fetch_prices):
    """Fetch, render, encode and push the chart through the EvenHub path of `session`
    (a GlassesSession-like object with next_magic() and async request(sid, payload, magic, ...)).
    Returns {'symbol', 'points', 'bytes'}. RuntimeError for no session / Pillow missing / no data /
    glasses not acking the image."""
    if session is None:
        raise RuntimeError('glasses not connected')
    _pillow()                                                           # fail early, before network
    prices, quote = await fetch(symbol)
    sym = quote.get('code', str(symbol).upper())
    img = render_chart(sym, prices)
    await push_image(session, img)
    return {'symbol': sym, 'points': len(prices), 'bytes': IMG_W * IMG_H // 2}


async def push_image(session, img):
    """Shared EvenHub helper: encode a PIL image (288x144 grey) as a raw 4 bpp EvenHub image page and
    push it through `session`. Returns the encoded byte count. RuntimeError for no session / no ack."""
    if session is None:
        raise RuntimeError('glasses not connected')
    page, frags = build_chart_messages(img, session.next_magic)
    await _send_all(session, page, frags)
    return IMG_W * IMG_H // 2


async def _send_all(session, page, frags):
    sid = eh.SID_EVENHUB
    pb = await session.request(sid, page, _magic_of(page), label='eh-chart-page')
    if pb is None:
        raise RuntimeError('glasses did not acknowledge the chart page (EvenHub experimental)')
    for f in frags:
        pb = await session.request(sid, f, _magic_of(f), label='eh-chart-image')
        if rt.ack_code(pb, rt.CMD_IMAGE_ACK) != rt.OK_CODE[rt.CMD_IMAGE_ACK]:
            raise RuntimeError('glasses rejected a chart image fragment (EvenHub experimental)')
        await asyncio.sleep(0)


def _magic_of(payload):
    """The envelope's field 2 is the magic (build wrap_even_hub: 1 cmd, 2 magic)."""
    return eh.read_varint_field(payload, 2)
