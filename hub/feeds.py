"""News sources for the glasses' news widget.

The widget holds 5 articles at a time (the glasses' news FIFO). This module fetches stories from
one or more free RSS/Atom feeds, interleaves them (so choosing BBC + Hacker News gives a mix),
skips titles already shown (so "scroll down to refresh" brings new ones), and turns each linked
page into plain readable text for the widget's article view.

Article text: Jina AI Reader (r.jina.ai, free, no key) first, then a plain <p>-tag fallback, then
the feed's own summary. Text is cleaned for the glasses: no markdown, no emoji or other symbols
the display font lacks, paragraphs separated by a blank line, trimmed at a sentence boundary.
"""
import asyncio
import html
import re
import xml.etree.ElementTree as ET

import aiohttp

FEEDS = {
    'hn': ('Hacker News', 'https://news.ycombinator.com/rss'),
    'bbc': ('BBC World', 'https://feeds.bbci.co.uk/news/world/rss.xml'),
    'bbc_tech': ('BBC Tech', 'https://feeds.bbci.co.uk/news/technology/rss.xml'),
    'npr': ('NPR', 'https://feeds.npr.org/1001/rss.xml'),
    'guardian': ('The Guardian', 'https://www.theguardian.com/world/rss'),
    'aljazeera': ('Al Jazeera', 'https://www.aljazeera.com/xml/rss/all.xml'),
    'ars': ('Ars Technica', 'https://feeds.arstechnica.com/arstechnica/index'),
    'verge': ('The Verge', 'https://www.theverge.com/rss/index.xml'),
    'techcrunch': ('TechCrunch', 'https://techcrunch.com/feed/'),
}
DEFAULT_FEEDS = ['hn']
ARTICLE_MAX_CHARS = 3000   # the widget accepts up to 7000 bytes of body (app limit)
TITLE_MAX_BYTES, SOURCE_MAX_BYTES = 126, 62   # app limits (app_behaviour_details.md §2)
FETCH_CONCURRENCY = 5      # feeds / article pages fetched at the same time
FEED_TIMEOUT_S = 15        # per feed (download + parse)
ARTICLE_TIMEOUT_S = 25     # per article (Jina 12 s + direct 8 s + slack)
UA = {'User-Agent': 'Mozilla/5.0 (compatible; G2Hub/1.0)'}

# Characters outside Latin/Greek/Cyrillic/common punctuation (emoji, pictographs) are dropped:
# the glasses' font has no glyphs for them.
_UNSUPPORTED = re.compile('[\U0001F000-\U0001FFFF☀-➿️‍]')


def clean_for_glasses(text):
    text = html.unescape(text or '')
    text = _UNSUPPORTED.sub('', text)
    text = text.replace('‘', "'").replace('’', "'").replace('“', '"').replace('”', '"')
    text = text.replace('‐', '-').replace('‑', '-').replace('‒', '-')
    text = text.replace('–', '-').replace('—', ' - ').replace('…', '...').replace('\xa0', ' ')
    return text


def limit_bytes(text, max_bytes):
    b = (text or '').encode('utf-8')
    return text if len(b) <= max_bytes else b[:max_bytes - 3].decode('utf-8', 'ignore') + '...'


def smart_trim(text, limit):
    """Cut at the last sentence end before `limit` (if it keeps at least 60% of the text)."""
    if len(text) <= limit:
        return text
    cut = text[:limit]
    last = max(cut.rfind('. '), cut.rfind('.\n'), cut.rfind('? '), cut.rfind('! '))
    return cut[:last + 1] if last > limit * 0.6 else cut.rstrip() + '...'


def _paragraphs(text):
    lines = [l.strip() for l in text.splitlines()]
    paras, buf = [], []
    for line in lines + ['']:
        if line:
            buf.append(line)
        elif buf:
            paras.append(' '.join(buf))
            buf = []
    skip = ('Sign in', 'Subscribe', 'Login', 'Log in', 'Cookie', 'Privacy', 'Copyright', 'All rights reserved',
            'Terms of', '©', 'Advertisement', 'URL Source:', 'Title:', 'Published Time:', 'Author:', 'Image:')
    return [p for p in paras if len(p) > 40 and not p.startswith(skip)]


def _clean_jina(text):
    i = text.find('Markdown Content:')
    if i != -1:
        text = text[i + len('Markdown Content:'):]
    text = re.sub(r'!\[.*?\]\(.*?\)', '', text)
    text = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', text)
    text = re.sub(r'```[\s\S]*?```', '', text)
    text = re.sub(r'^#+\s+', '', text, flags=re.M)
    text = re.sub(r'^[-*]{3,}\s*$', '', text, flags=re.M)
    text = re.sub(r'^\s*[-*+]\s+', '', text, flags=re.M)
    text = re.sub(r'[*_`]', '', text)
    return '\n\n'.join(_paragraphs(clean_for_glasses(text)))


async def fetch_article_text(sess, url, max_chars=ARTICLE_MAX_CHARS):
    """Readable plain text of an article page, or '' if nothing usable was found."""
    if not url or 'news.ycombinator.com' in url:
        return ''
    try:
        async with sess.get('https://r.jina.ai/' + url, headers={**UA, 'Accept': 'text/plain'},
                            timeout=aiohttp.ClientTimeout(total=12)) as r:
            if r.status == 200:
                cleaned = _clean_jina(await r.text(errors='replace'))
                if len(cleaned) > 80:
                    return smart_trim(cleaned, max_chars)
    except Exception:
        pass
    try:
        async with sess.get(url, headers=UA, allow_redirects=True, timeout=aiohttp.ClientTimeout(total=8)) as r:
            if 'html' not in r.headers.get('Content-Type', '').lower():
                return ''
            page = await r.text(errors='replace')
        paras = [re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', '', p)).strip()
                 for p in re.findall(r'<p[^>]*>(.*?)</p>', page, re.S | re.I)]
        text = clean_for_glasses('\n\n'.join(p for p in paras if len(p) > 40)[:max_chars * 2])
        return smart_trim(text, max_chars) if len(text) > 40 else ''
    except Exception:
        return ''


def _text(el, *names):
    for n in names:
        found = el.find(n)
        if found is not None and (found.text or '').strip():
            return found.text.strip()
        if found is not None and found.get('href'):
            return found.get('href')
    return ''


def parse_feed(xml_text):
    """RSS 2.0 or Atom → list of {title, url, summary}."""
    xml_text = re.sub(r'\sxmlns(:\w+)?="[^"]+"', '', xml_text, count=0)   # drop namespaces
    xml_text = re.sub(r'<(/?)\w+:(\w+)', r'<\1\2', xml_text)               # a:b → b
    root = ET.fromstring(xml_text.encode('utf-8', 'replace'))
    items = root.findall('.//item') or root.findall('.//entry')
    out = []
    for it in items:
        title = clean_for_glasses(re.sub(r'<[^>]+>', '', _text(it, 'title'))).strip()
        link = _text(it, 'link')
        summary = clean_for_glasses(re.sub(r'<[^>]+>', ' ', _text(it, 'description', 'summary', 'content')))
        if title:
            out.append({'title': title, 'url': link, 'summary': re.sub(r'\s+', ' ', summary).strip()})
    return out


async def _fetch_feed(sess, feed):
    name, url = FEEDS.get(feed, (feed, feed))
    async with sess.get(url, headers=UA, timeout=aiohttp.ClientTimeout(total=12)) as r:
        body = await r.text(errors='replace')
    items = await asyncio.to_thread(parse_feed, body)
    return [{**i, 'source': name} for i in items]


async def _bounded(sem, coro, timeout):
    async with sem:
        return await asyncio.wait_for(coro, timeout)


async def fetch_stories(feeds, count=5, skip_titles=(), concurrency=FETCH_CONCURRENCY):
    """`count` stories interleaved across `feeds` (ids from FEEDS or custom RSS URLs), skipping
    titles in skip_titles, each with extracted article text. Returns (stories, errors).

    Feeds are fetched in parallel (at most `concurrency` at once, FEED_TIMEOUT_S each), then the
    picked articles' pages in parallel the same way. Order is the same as a serial fetch."""
    skip, errors = set(skip_titles), []
    feeds = list(feeds or DEFAULT_FEEDS)
    sem = asyncio.Semaphore(max(1, concurrency))
    async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=60, connect=8)) as sess:
        results = await asyncio.gather(*(_bounded(sem, _fetch_feed(sess, f), FEED_TIMEOUT_S) for f in feeds),
                                       return_exceptions=True)
        per_feed = []
        for feed, res in zip(feeds, results):
            if isinstance(res, asyncio.TimeoutError):
                errors.append(f'{feed}: timed out after {FEED_TIMEOUT_S}s')
            elif isinstance(res, BaseException):
                if isinstance(res, asyncio.CancelledError):
                    raise res
                errors.append(f'{feed}: {res}')
            else:
                per_feed.append([i for i in res if i['title'] not in skip])
        picked = []
        while len(picked) < count and any(per_feed):
            for lst in per_feed:
                if lst and len(picked) < count:
                    picked.append(lst.pop(0))
        texts = await asyncio.gather(*(_bounded(sem, fetch_article_text(sess, item['url']), ARTICLE_TIMEOUT_S)
                                       for item in picked), return_exceptions=True)
        stories = []
        for item, text in zip(picked, texts):
            if isinstance(text, asyncio.CancelledError):
                raise text
            if isinstance(text, BaseException):
                text = ''
            content = text or smart_trim(item['summary'], ARTICLE_MAX_CHARS) or item['url'] or item['title']
            stories.append({'title': limit_bytes(item['title'], TITLE_MAX_BYTES),
                            'source': limit_bytes(item['source'], SOURCE_MAX_BYTES), 'url': item['url'],
                            'content': content, 'text_extracted': bool(text)})
    return stories, errors
