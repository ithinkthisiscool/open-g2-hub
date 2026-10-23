"""News widget (SID 0x01 V3 FIFO): sources, fetching, cache, the push sequence and auto-refresh.
Fetching lives here; pushing is the sync engine's 'news' section (hub/sync.py), which pushes the
cached stories after a refresh, on connect and when the glasses ask for more."""
import asyncio
import time

from aiohttp import web

from g2 import dashboard as rdp
from g2 import evenhub as eh
from hub import feeds, state, sync
from hub.events import on_event
from hub.glasses import decode_dashboard_ack, start_hub_heartbeat, stop_hub_heartbeat

HN_CACHE_MAX_AGE_S = state.HN_CACHE_MAX_AGE_S
_fetch_locks = {}          # one per event loop (each test runs its own)


def _fetch_lock():
    loop = asyncio.get_running_loop()
    lock = _fetch_locks.get(loop)
    if lock is None:
        _fetch_locks.clear()
        lock = _fetch_locks[loop] = asyncio.Lock()
    return lock


async def push_news(articles_in=None, title='News', source='', content=''):
    """Push up to N articles to the native dashboard news widget (V3 FIFO path; every step acked
    live 2026-09-29). The sequence, matching the official app's capture:

      0. Restart the EvenHub heartbeat if it was stopped (SID 0x01 only answers while it runs)
      1. Reset the device news FIFO (AppResetClearAllDataMsg, cmdId 13)
      2. FIFO count request (cmdId 7) -> slot count (always 5 so far)
      3. One AppSendNewsData (cmdId 9, field 11) per slot, report_time in milliseconds
      4. Stop the heartbeat so the native dashboard takes the screen again

    The older probe / V2-watermark / display-enable steps are gone: the V2 rNewsWidget path always
    answers PARAMETER_ERROR. Known gap: the app sends report_time as LOCAL wall-clock ms, we send
    UTC ms (article times may be shifted by the UTC offset; needs a live check).

    Returns (http_status, body)."""
    session = state.current_session()
    if session is None:
        return 503, {'error': 'not connected'}

    # Step 0: Ensure EvenHub heartbeat is running — SID=0x01 (native dashboard protocol) only
    # responds when the EvenHub session is active (heartbeat sending on SID=0xe0). If the
    # previous push stopped the heartbeat (to show native dashboard), restart it now so the
    # firmware's SID=0x01 ACK path is alive again. A successful create-page is NOT required —
    # just heartbeat pings are sufficient (confirmed: create-page failed sessions still ACK
    # SID=0x01 commands as long as heartbeat is running).
    if start_hub_heartbeat(session):
        on_event('Restarting EvenHub heartbeat for SID=0x01 activation...', level='info')
        await asyncio.sleep(2)  # give device 2s to see the heartbeat and open SID=0x01

    # Step 0.5: Clear device news FIFO (AppResetClearAllDataMsg, cmdId=13).
    # The device may have old news stored from a previous Even app session occupying slot 0.
    # Our push with newsId=0 gets silently rejected when slot 0 is already occupied by older
    # content — the device shows the cached version instead of ours. Reset ensures clean slots.
    on_event('news: clearing device FIFO (AppResetClearAllDataMsg, cmdId=13)...', level='info')
    magic_reset = session.next_magic()
    payload_reset = rdp.build_news_reset(magic_reset)
    raw_reset = await session._send_and_get_payload(rdp.SID_DASHBOARD, eh.FLAG_REQUEST, magic_reset,
                                                     payload_reset, session.next_seq(),
                                                     'news reset', timeout_s=3.0)
    reset_result = decode_dashboard_ack(raw_reset)
    on_event(f'news reset: {reset_result}', level='ok' if raw_reset else 'warn')
    await asyncio.sleep(0.5)

    # Step 1: V3 FIFO count (cmdId=7) — exact real app pattern (btsnoop confirmed).
    # Real app: cmdId=7 → count=5 → immediately send 5 cmdId=9 items. No probe, no display_enable.
    on_event('news: FIFO count (cmdId=7)...', level='info')
    magic = session.next_magic()
    payload = rdp.build_news_fifo_count_request_v3(magic)
    raw = await session._send_and_get_payload(rdp.SID_DASHBOARD, eh.FLAG_REQUEST, magic, payload,
                                               session.next_seq(), 'news fifo count', timeout_s=4.0)
    count_value = 5  # default; device always returns 5
    if raw is not None:
        resp = eh.read_bytes_field(raw, 10)
        if resp is not None:
            count_value = eh.read_varint_field(resp, 1, 5) or 5
    on_event(f'news FIFO count: {count_value}', level='ok' if raw else 'warn')
    await asyncio.sleep(0.2)

    # report_time in MILLISECONDS (btsnoop confirmed: real app f7=1800000000123).
    # Sending seconds makes news appear to be from Jan 1970 → device shows newer cached content.
    # The app sends local wall-clock ms (UTC ms + the phone's UTC offset; resolved 2026-10-01).
    report_time = int((time.time() + time.localtime().tm_gmtoff) * 1000)

    # Build article list: either N distinct articles (HN mode) or single article replicated.
    # Real app always fills ALL FIFO slots (5 items). Device cycles through them in ~10s rotation.
    if articles_in and len(articles_in) > 0:
        article_list = (articles_in * ((count_value // len(articles_in)) + 1))[:count_value]
    else:
        article_list = [{'title': title, 'source': source, 'content': content}] * count_value

    max_content = max(len(a.get('content', '')) for a in article_list)
    timeout_s = 4.0 if max_content > 600 else 3.0 if max_content > 200 else 1.5
    push_results = []
    all_acked = True
    for idx in range(count_value):
        art = article_list[idx]
        cur_title = art.get('title', title)
        cur_source = art.get('source', source)
        cur_content = art.get('content', content)
        on_event(f'news: item {idx}/{count_value-1} (news_id={idx}): "{cur_title[:40]}"', level='info')
        magic = session.next_magic()
        payload = rdp.build_news_push_v3(magic, news_id=idx, title=cur_title, report_time=report_time,
                                         source=cur_source, content=cur_content,
                                         session_id=0, session_status=0,
                                         session_total_count=count_value, session_news_index=idx)
        raw = await session._send_and_get_payload(rdp.SID_DASHBOARD, eh.FLAG_REQUEST, magic, payload,
                                                   session.next_seq(), f'news item {idx}',
                                                   timeout_s=timeout_s + 1.0)
        acked = raw is not None
        if acked:
            f12 = eh.read_bytes_field(raw, 12)
            news_status = eh.read_varint_field(f12, 5, 0) if f12 else 0
            on_event(f'  ack idx={idx} newsStatus={news_status} raw={raw.hex()[:20]}',
                     level='ok' if news_status == 0 else 'warn')
        else:
            on_event(f'  no ack for idx={idx}', level='warn')
            all_acked = False
        push_results.append({'idx': idx, 'acked': acked})
        await asyncio.sleep(0.15)

    on_event(f'news: {count_value} items sent. Display rotates in ~10s.', level='ok' if all_acked else 'warn')

    # Stop heartbeat — native dashboard takes over in ~5s. Display rotation is ~10s per item.
    if stop_hub_heartbeat(session):
        on_event('Heartbeat stopped — news widget shows in native dashboard in ~5–10s', level='ok')

    return 200, {
        'fifo_count': count_value,
        'push_results': push_results,
        'all_acked': all_acked,
    }


async def api_push_news_full_sequence(request):
    """/api/push_news → the full V3 two-phase commit sequence (see push_news). Legacy direct push
    of the given articles (scripts, tests); the next news sync replaces them."""
    if state.current_session() is None:
        return web.json_response({'error': 'not connected'}, status=503)
    data = await request.json()
    # Accept either a list of articles (HN mode) or a single title/source/content
    async with sync.ENGINE.exclusive():
        status, body = await push_news(data.get('articles', None), data.get('title', 'News'),
                                       data.get('source', ''), data.get('content', ''))
    return web.json_response(body, status=status)


async def api_reset_news(request):
    """Send AppResetClearAllDataMsg (cmdId=13) to wipe the device's news FIFO.
    Use this before a news push when the device is showing stale content from a previous session."""
    session = state.current_session()
    if session is None:
        return web.json_response({'error': 'not connected'}, status=503)
    async with sync.ENGINE.exclusive():
        if start_hub_heartbeat(session):
            await asyncio.sleep(2)
        on_event('news reset: sending AppResetClearAllDataMsg (cmdId=13)...', level='info')
        magic = session.next_magic()
        payload = rdp.build_news_reset(magic)
        raw = await session._send_and_get_payload(rdp.SID_DASHBOARD, eh.FLAG_REQUEST, magic, payload,
                                                   session.next_seq(), 'news reset', timeout_s=4.0)
    result = decode_dashboard_ack(raw)
    on_event(f'news reset result: {result}', level='ok' if raw else 'warn')
    return web.json_response({'result': result})


def news_feeds():
    """News sources chosen for the active glasses (feed ids from hub/feeds.py or RSS URLs)."""
    cfg = state.load_hub_state().get('news') or {}
    return cfg.get('feeds') or list(feeds.DEFAULT_FEEDS)


def refresh_in_background(force_fetch=True, scope='app'):
    return state.SUP.spawn(auto_push_hn(force_fetch=force_fetch), name='news-refresh', scope=scope)


def articles(stories):
    return [{'title': s['title'], 'source': s.get('source', 'Hacker News'),
             'content': s.get('content') or s.get('url', s['title'])} for s in stories]


async def api_news_feeds(request):
    """GET → available sources + the active pair's choice. POST {feeds: [...]} → save + refresh."""
    if request.method == 'GET':
        return web.json_response({'available': {k: v[0] for k, v in feeds.FEEDS.items()}, 'selected': news_feeds()})
    data = await request.json()
    chosen = [str(f).strip() for f in data.get('feeds', []) if str(f).strip()]
    bad = [f for f in chosen if f not in feeds.FEEDS and not f.startswith(('http://', 'https://'))]
    if not chosen or bad:
        return web.json_response({'error': f'choose at least one source (unknown: {bad})'}, status=400)
    state.save_hub_state('news', {'feeds': chosen})
    on_event(f'News sources → {", ".join(chosen)}; refreshing', level='ok')
    refresh_in_background(force_fetch=True)
    return web.json_response({'selected': chosen})


async def load_stories(force_fetch=False):
    """The stories for the glasses: the cache when it is fresh and from the chosen sources,
    otherwise fetched now (force_fetch: always, skipping stories already shown). Serialized.
    Returns the list ([] when nothing could be fetched)."""
    async with _fetch_lock():
        return await _load_stories_locked(force_fetch)


async def _load_stories_locked(force_fetch):
    cache = await state.aload_news_cache()
    now = time.time()
    if cache and cache.get('feeds', ['hn']) != news_feeds():
        cache = None   # the chosen sources changed since the cache was filled
    if not force_fetch and cache and (now - cache.get('fetched_at', 0)) < HN_CACHE_MAX_AGE_S:
        stories = cache['stories']
        age_min = int((now - cache['fetched_at']) / 60)
        on_event(f'News: {len(stories)} cached stories ({age_min}m old)', level='info')
        return stories
    chosen = news_feeds()
    on_event(f'News: fetching fresh stories from {", ".join(chosen)} + article text...', level='info')
    seen = (cache or {}).get('seen_titles', []) if force_fetch else []
    try:
        stories, errors = await feeds.fetch_stories(chosen, 5, skip_titles=seen)
        if force_fetch and not stories:
            on_event('News refresh: every story already shown — starting over from the top', level='info')
            seen = []
            stories, errors = await feeds.fetch_stories(chosen, 5)
        for err in errors:
            on_event(f'News source failed: {err}', level='warn')
    except Exception as e:
        on_event(f'News fetch failed: {e}', level='warn')
        return (cache or {}).get('stories', [])
    if not stories:
        return (cache or {}).get('stories', [])
    seen = (seen + [s['title'] for s in stories])[-60:]
    await state.asave_news_cache({'stories': stories, 'fetched_at': now, 'seen_titles': seen, 'feeds': chosen,
                                  **({'last_pushed_at': cache['last_pushed_at']} if cache and cache.get('last_pushed_at') else {})})
    extracted = sum(1 for s in stories if s.get('text_extracted'))
    on_event(f'News: fetched {len(stories)} stories ({extracted} with article text)', level='ok')
    return stories


async def mark_pushed():
    cache = await state.aload_news_cache()
    if cache:
        await state.asave_news_cache({**cache, 'last_pushed_at': time.time()})


async def auto_push_hn(force_fetch=False):
    """Refresh the stories (fetch when stale; force_fetch: always) and let the sync engine push
    them: at once when connected, on the next connect otherwise. Called every 30 min, by the
    widget's scroll-to-refresh (force_fetch=True), by Refresh in the page and when the sources
    change. A refresh during a push queues exactly one more push (the engine coalesces)."""
    stories = await load_stories(force_fetch=force_fetch)
    if not stories:
        return False
    if state.current_session() is None:
        on_event('News: glasses not connected, stories kept for the next connect', level='info')
        if force_fetch:
            sync.mark('news')
        return False
    return sync.ENGINE.push_now('news')


async def news_refresh_loop():
    """Background task: re-fetch the news and push it every HN_CACHE_MAX_AGE_S seconds."""
    await asyncio.sleep(60)  # wait 60s after startup before first background refresh
    while True:
        try:
            await auto_push_hn()
        except asyncio.CancelledError:
            raise
        except Exception as e:
            on_event(f'News refresh failed: {e}', level='warn')
        await asyncio.sleep(HN_CACHE_MAX_AGE_S)


async def api_fetch_hacker_news(request):
    """Fetch top HN stories (with article text), cache to disk, return to browser."""
    chosen = news_feeds()
    on_event(f'News fetch requested ({", ".join(chosen)})...', level='info')
    try:
        stories, errors = await feeds.fetch_stories(chosen, 5)
    except Exception as e:
        on_event(f'News fetch error: {e}', level='err')
        return web.json_response({'error': str(e)}, status=503)
    now = time.time()
    await state.asave_news_cache({'stories': stories, 'fetched_at': now, 'feeds': chosen,
                                  'seen_titles': [st['title'] for st in stories]})
    extracted = sum(1 for s in stories if s.get('text_extracted'))
    on_event(f'HN fetch: {len(stories)} stories ({extracted} with article text)', level='ok')
    return web.json_response({'stories': stories, 'fetched_at': now})


async def api_auto_push_hn(request):
    """Fresh stories now: fetch (when stale) and let the sync engine push them."""
    state.SUP.spawn(auto_push_hn(), name='news-auto-push', scope='app')
    return web.json_response({'status': 'started'})


async def api_news_status(request):
    """Return cache metadata for the UI status line."""
    cache = await state.aload_news_cache()
    now = time.time()
    if not cache:
        return web.json_response({'cached': False, 'sync': sync.status('news')})
    age_s = int(now - cache.get('fetched_at', 0))
    last_pushed = cache.get('last_pushed_at')
    pushed_s = int(now - last_pushed) if last_pushed else None
    stories = cache.get('stories', [])
    return web.json_response({
        'cached': True,
        'story_count': len(stories),
        'age_s': age_s,
        'age_min': age_s // 60,
        'pushed_s': pushed_s,
        'pushed_min': pushed_s // 60 if pushed_s is not None else None,
        'next_refresh_s': max(0, HN_CACHE_MAX_AGE_S - age_s),
        'titles': [s['title'][:50] for s in stories[:5]],
        'sources': [s.get('source', '') for s in stories[:5]],
        'sync': sync.status('news'),
    })


ROUTES = [
    # /api/push_news → full V3 two-phase commit sequence (confirmed best path)
    ('POST', '/api/push_news', api_push_news_full_sequence),
    ('POST', '/api/reset_news', api_reset_news),
    ('GET', '/api/fetch_hacker_news', api_fetch_hacker_news),
    ('POST', '/api/auto_push_hn', api_auto_push_hn),
    ('GET', '/api/news_status', api_news_status),
    ('GET', '/api/news/feeds', api_news_feeds),
    ('POST', '/api/news/feeds', api_news_feeds),
]
