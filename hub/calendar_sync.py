"""Pull events from a subscribed calendar (ICS / iCalendar feed) into the hub's event shape.

Stdlib-only parser (no `icalendar` dependency). Handles:
  - line unfolding, text unescaping, SUMMARY / LOCATION / UID / STATUS
  - DTSTART / DTEND / DURATION as DATE (all-day), DATE-TIME UTC ("...Z"), TZID (zoneinfo) or floating (local)
  - RRULE expansion for FREQ=DAILY / WEEKLY (BYDAY) / MONTHLY (BYMONTHDAY, BYDAY with ordinals) / YEARLY,
    with INTERVAL, COUNT, UNTIL, plus EXDATE and RECURRENCE-ID overrides
  - NOT handled: BYSETPOS, HOURLY/MINUTELY/SECONDLY rules, RDATE (those events show only their first/base instance
    or are skipped, never a crash); unknown TZIDs (e.g. Windows names) fall back to the hub's local time

Only a short window (today .. +3 days) is kept; calendar_events.upcoming() then applies the app's
today/tomorrow rules at display time. Event ids are prefixed "ics:" so they can be told from manual ones.
"""
import calendar as _cal
import re
from datetime import date, datetime, time as dtime, timedelta, timezone

try:
    from zoneinfo import ZoneInfo
except ImportError:      # pragma: no cover
    ZoneInfo = None

ID_PREFIX = 'ics:'
WINDOW_DAYS = 3
MAX_BYTES = 5_000_000
MAX_CANDIDATES = 20000
_DAYS = ['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU']


class SyncError(Exception):
    pass


# ───────────────────────── fetching ─────────────────────────
def normalize_url(url):
    url = (url or '').strip()
    if url.lower().startswith('webcal://'):
        url = 'https://' + url[9:]
    if url and not re.match(r'^https?://\S+$', url, re.I):
        raise ValueError('calendar URL must start with https:// (or webcal://)')
    return url


async def fetch_text(url, timeout=20):
    """GET the feed. Raises SyncError (without echoing the URL: it often contains a secret token)."""
    import aiohttp
    try:
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=timeout)) as s:
            async with s.get(url, headers={'User-Agent': 'g2hub-calendar-sync'}) as r:
                if r.status != 200:
                    raise SyncError(f'calendar server answered HTTP {r.status}')
                body = await r.content.read(MAX_BYTES + 1)
    except SyncError:
        raise
    except Exception as e:
        raise SyncError(f'could not fetch calendar ({type(e).__name__})') from None
    if len(body) > MAX_BYTES:
        raise SyncError('calendar feed is too large')
    return body.decode('utf-8', 'replace')


# ───────────────────────── parsing ─────────────────────────
def _unescape(v):
    return re.sub(r'\\(.)', lambda m: '\n' if m.group(1) in 'nN' else m.group(1), v)


def _components(text):
    """Yield one list of (NAME, params, value) per VEVENT."""
    text = text.replace('\r\n', '\n').replace('\r', '\n')
    text = re.sub(r'\n[ \t]', '', text)
    cur = None
    for line in text.split('\n'):
        if not line:
            continue
        up = line.upper()
        if up == 'BEGIN:VEVENT':
            cur = []
        elif up == 'END:VEVENT':
            if cur is not None:
                yield cur
            cur = None
        elif cur is not None and ':' in line:
            head, _, value = line.partition(':')
            parts = head.split(';')
            params = {}
            for p in parts[1:]:
                k, _, v = p.partition('=')
                params[k.upper()] = v.strip('"')
            cur.append((parts[0].upper(), params, value))


def _local(naive):
    return naive.astimezone()      # naive → system local zone (DST aware)


def _parse_dt(value, params):
    """→ (date, True) for all-day; (aware datetime, False) otherwise; tz = tzinfo or None for floating."""
    v = value.strip()
    if params.get('VALUE') == 'DATE' or re.fullmatch(r'\d{8}', v):
        return datetime.strptime(v[:8], '%Y%m%d').date(), True, None
    if v.endswith('Z'):
        return datetime.strptime(v[:-1], '%Y%m%dT%H%M%S').replace(tzinfo=timezone.utc), False, timezone.utc
    naive = datetime.strptime(v, '%Y%m%dT%H%M%S')
    tzid = params.get('TZID')
    if tzid and ZoneInfo:
        try:
            tz = ZoneInfo(tzid)
            return naive.replace(tzinfo=tz), False, tz
        except Exception:
            pass
    return _local(naive), False, None      # floating / unknown TZID → local


def _duration(v):
    m = re.fullmatch(r'([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?', v.strip())
    if not m:
        return None
    sign = -1 if m.group(1) == '-' else 1
    w, d, h, mi, s = (int(x or 0) for x in m.groups()[1:])
    return sign * timedelta(weeks=w, days=d, hours=h, minutes=mi, seconds=s)


def _rule(value):
    r = {}
    for part in value.split(';'):
        k, _, v = part.partition('=')
        r[k.upper()] = v
    return r


def _byday(spec):
    out = []
    for tok in spec.split(','):
        m = re.fullmatch(r'([+-]?\d+)?(MO|TU|WE|TH|FR|SA|SU)', tok.strip().upper())
        if m:
            out.append((int(m.group(1)) if m.group(1) else 0, _DAYS.index(m.group(2))))
    return out


def _month_days(year, month, bymonthday, byday, fallback_day):
    """Dates within one month selected by BYMONTHDAY / BYDAY(+ordinal) / the start's day-of-month."""
    n = _cal.monthrange(year, month)[1]
    days = set()
    if bymonthday:
        for d in bymonthday:
            d = d if d > 0 else n + d + 1
            if 1 <= d <= n:
                days.add(d)
    if byday:
        for ordn, wd in byday:
            matches = [d for d in range(1, n + 1) if date(year, month, d).weekday() == wd]
            if ordn == 0:
                days.update(matches)
            elif matches and abs(ordn) <= len(matches):
                days.add(matches[ordn - 1] if ordn > 0 else matches[ordn])
    if not bymonthday and not byday and fallback_day <= n:
        days.add(fallback_day)
    return sorted(date(year, month, d) for d in days)


def _candidates(rule, start, until_date, limit_date):
    """Yield wall-clock datetimes (naive) of a recurrence in order, from `start`, until a limit."""
    freq = rule.get('FREQ', '')
    interval = max(1, int(rule.get('INTERVAL') or 1))
    byday = _byday(rule['BYDAY']) if rule.get('BYDAY') else []
    bymd = [int(x) for x in rule['BYMONTHDAY'].split(',')] if rule.get('BYMONTHDAY') else []
    t = start.time()
    sd = start.date()
    last = min(x for x in (until_date, limit_date) if x is not None)
    k = 0
    while True:
        if freq == 'DAILY':
            days = [sd + timedelta(days=k * interval)]
        elif freq == 'WEEKLY':
            monday = sd - timedelta(days=sd.weekday()) + timedelta(weeks=k * interval)
            wds = sorted({wd for _, wd in byday}) or [sd.weekday()]
            days = [monday + timedelta(days=wd) for wd in wds]
        elif freq == 'MONTHLY':
            mi = sd.month - 1 + k * interval
            days = _month_days(sd.year + mi // 12, mi % 12 + 1, bymd, byday, sd.day)
        elif freq == 'YEARLY':
            months = [int(x) for x in rule['BYMONTH'].split(',')] if rule.get('BYMONTH') else [sd.month]
            days = [d for m in months for d in _month_days(sd.year + k * interval, m, bymd, byday, sd.day)]
        else:
            return
        if days and min(days) > last:
            return
        if k > MAX_CANDIDATES:
            return
        for d in days:
            if d >= sd:
                yield datetime.combine(d, t)
        k += 1


def _instances(ev, wstart, wend):
    """Occurrences of one VEVENT overlapping [wstart, wend) as (start_ts, end_ts, orig_start_ts)."""
    props = {}
    for name, params, value in ev:
        props.setdefault(name, []).append((params, value))
    if 'DTSTART' not in props:
        return []
    start, all_day, tz = _parse_dt(props['DTSTART'][0][1], props['DTSTART'][0][0])
    if 'DTEND' in props:
        end, _, _ = _parse_dt(props['DTEND'][0][1], props['DTEND'][0][0])
        span = end - start
    elif 'DURATION' in props and _duration(props['DURATION'][0][1]) is not None:
        span = _duration(props['DURATION'][0][1])
    else:
        span = timedelta(days=1) if all_day else timedelta(0)
    if span <= timedelta(0):
        span = timedelta(days=1) if all_day else timedelta(hours=1)

    def to_dt(wall):             # naive wall clock → aware
        if all_day:
            return _local(datetime.combine(wall.date(), dtime()))
        if tz is None:
            return _local(wall)
        return wall.replace(tzinfo=tz)

    def to_wall(d, ad):          # parsed value → naive wall clock in the event's own zone
        if ad:
            return datetime.combine(d, dtime())
        if tz is None:
            return d.astimezone().replace(tzinfo=None)
        return d.replace(tzinfo=None)

    base_wall = to_wall(start, all_day)
    if tz is timezone.utc and not all_day:
        to_dt = lambda w: w.replace(tzinfo=timezone.utc)   # noqa: E731

    exdates = set()
    for params, value in props.get('EXDATE', []):
        for v in value.split(','):
            try:
                d, ad, _ = _parse_dt(v, params)
                exdates.add(to_wall(d, ad))
            except ValueError:
                pass

    walls = [base_wall]
    if 'RRULE' in props:
        rule = _rule(props['RRULE'][0][1])
        until = None
        if rule.get('UNTIL'):
            try:
                u, uad, _ = _parse_dt(rule['UNTIL'], {})
                until = u if uad else u.astimezone().date()
            except ValueError:
                until = None
        limit = (wend + span).astimezone().date() + timedelta(days=1)
        count = int(rule['COUNT']) if rule.get('COUNT', '').isdigit() else None
        walls = []
        for i, w in enumerate(_candidates(rule, base_wall, until, limit)):
            if count is not None and i >= count:
                break
            walls.append(w)
        if rule.get('FREQ') not in ('DAILY', 'WEEKLY', 'MONTHLY', 'YEARLY'):
            walls = [base_wall]
    out = []
    for w in walls:
        if w in exdates:
            continue
        s = to_dt(w)
        e = s + span if not all_day else to_dt(w + span)
        if s < wend and e > wstart:
            out.append((s.timestamp(), e.timestamp(), s.timestamp(), all_day))
    return out


def parse_ics(text, now=None):
    """ICS text → list of hub events (all_day/timed) overlapping today..today+WINDOW_DAYS, earliest first.
    Raises SyncError when the text is not a calendar at all."""
    import time as _t
    if 'BEGIN:VCALENDAR' not in (text or '').upper():
        raise SyncError('that URL did not return an ICS calendar')
    now = _t.time() if now is None else now
    today = datetime.fromtimestamp(now).date()
    wstart = _local(datetime.combine(today, dtime()))
    wend = _local(datetime.combine(today + timedelta(days=WINDOW_DAYS), dtime()))
    comps, overrides, events = [], {}, []
    for ev in _components(text):
        names = {n for n, _, _ in ev}
        if 'RECURRENCE-ID' in names:
            props = {n: (p, v) for n, p, v in ev}
            try:
                d, ad, _ = _parse_dt(props['RECURRENCE-ID'][1], props['RECURRENCE-ID'][0])
                key = (props.get('UID', ({}, ''))[1],
                       _local(datetime.combine(d, dtime())).timestamp() if ad else d.timestamp())
                overrides[key] = True
            except (ValueError, KeyError):
                pass
        comps.append(ev)
    for ev in comps:
        props = {n: (p, v) for n, p, v in ev}
        if props.get('STATUS', ({}, ''))[1].upper() == 'CANCELLED':
            continue
        try:
            res = _instances(ev, wstart, wend)
        except (ValueError, OverflowError, KeyError, TypeError):
            continue
        if not res:
            continue
        insts = res
        uid = props.get('UID', ({}, ''))[1]
        is_override = 'RECURRENCE-ID' in props
        title = _unescape(props.get('SUMMARY', ({}, ''))[1]).strip() or 'Event'
        loc = _unescape(props.get('LOCATION', ({}, ''))[1]).replace('\n', ', ').strip()
        for s, e, orig, all_day in insts:
            if not is_override and (uid, orig) in overrides:
                continue
            events.append({'id': f'{ID_PREFIX}{uid}@{int(s)}', 'title': title, 'location': loc,
                           'start': int(s), 'end': int(e), 'all_day': all_day, 'source': 'ics'})
    return sorted(events, key=lambda e: (e['start'], e['title']))


async def sync_ics(url, now=None, fetch=None):
    """Fetch + parse. Never raises: returns (events, note); note is '' on success, else a human reason."""
    try:
        url = normalize_url(url)
        if not url:
            return [], 'no calendar URL set'
        text = await (fetch or fetch_text)(url)
        return parse_ics(text, now), ''
    except SyncError as e:
        return [], str(e)
    except ValueError as e:
        return [], str(e)
    except Exception as e:      # parser bug / odd feed: report, never crash the hub
        return [], f'could not read calendar ({type(e).__name__})'
