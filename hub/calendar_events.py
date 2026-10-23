"""Calendar events for the glasses' schedule widget — formatted exactly like the official app.

Each event: {id, title, location, start, end, all_day} with start/end as unix seconds.

App rules (decompile, docs/research/app_behaviour_details.md §1):
  - only today's and tomorrow's events; timed events that already ended are dropped; duplicates
    (same title/start/end) removed; earliest first; at most 8
  - ONE event per message: scheduleTotal = n, scheduleNum = 0-based index
  - time string: "HH:mm-HH:mm" (24 h) or "hh:mm AM-hh:mm PM" (12 h), prefixed "Tmr " for tomorrow;
    all-day → "All day" / "Tmr All day"; an end of 00:00 is shown as 24:00
  - byte limits: title 175, location 282, time 62 — longer text is cut on a UTF-8 boundary to
    max-3 bytes and "..." appended
  - re-synced every 15 minutes and whenever something changes
"""
import time

MAX_EVENTS = 8
TITLE_MAX_BYTES, LOCATION_MAX_BYTES, TIME_MAX_BYTES = 175, 282, 62
REFRESH_S = 15 * 60


def limit_bytes(text, max_bytes):
    b = (text or '').encode('utf-8')
    if len(b) <= max_bytes:
        return text or ''
    return b[:max_bytes - 3].decode('utf-8', 'ignore') + '...'


def _clock(ts, h24, is_end=False):
    t = time.localtime(ts)
    if h24:
        s = time.strftime('%H:%M', t)
        return '24:00' if is_end and s == '00:00' else s
    return time.strftime('%I:%M %p', t)


def _day_offset(ts, now):
    a, b = time.localtime(ts), time.localtime(now)
    return round((time.mktime(a[:3] + (12, 0, 0, 0, 0, -1)) - time.mktime(b[:3] + (12, 0, 0, 0, 0, -1))) / 86400)


def time_string(ev, now=None, h24=False):
    now = time.time() if now is None else now
    prefix = 'Tmr ' if _day_offset(int(ev['start']), now) == 1 else ''
    if ev.get('all_day'):
        return prefix + 'All day'
    return f"{prefix}{_clock(int(ev['start']), h24)}-{_clock(int(ev['end']), h24, is_end=True)}"


def upcoming(events, now=None):
    """Today's and tomorrow's events the glasses should show (app rules above)."""
    now = time.time() if now is None else now
    seen, out = set(), []
    for e in sorted(events, key=lambda e: int(e['start'])):
        if _day_offset(int(e['start']), now) not in (0, 1) and not (int(e['start']) <= now < int(e['end'])):
            continue
        if not e.get('all_day') and int(e['end']) <= now:
            continue
        key = (e.get('title'), int(e['start']), int(e['end']))
        if key in seen:
            continue
        seen.add(key)
        out.append(e)
    return out[:MAX_EVENTS]


def to_schedules(events, now=None, h24=False):
    """[(title, location, time_str, end_ts)] for g2.dashboard.build_calendar_event_push."""
    return [(limit_bytes(e.get('title') or 'Event', TITLE_MAX_BYTES),
             limit_bytes(e.get('location') or '', LOCATION_MAX_BYTES),
             limit_bytes(time_string(e, now, h24), TIME_MAX_BYTES), int(e['end']))
            for e in upcoming(events, now)]


def normalize(raw, now=None):
    """Validate one event from the web UI / Claude. Accepts start/end unix seconds, or
    start + duration_min, or minutes_from_now + duration_min. Raises ValueError."""
    now = int(time.time() if now is None else now)
    title = str(raw.get('title') or '').strip()
    if not title:
        raise ValueError('event needs a title')
    if raw.get('start') is not None:
        start = int(raw['start'])
    elif raw.get('minutes_from_now') is not None:
        start = now + int(float(raw['minutes_from_now']) * 60)
    else:
        raise ValueError('event needs start or minutes_from_now')
    end = int(raw['end']) if raw.get('end') is not None else start + int(float(raw.get('duration_min') or 60) * 60)
    if end <= start:
        raise ValueError('event must end after it starts')
    return {'id': str(raw.get('id') or f'{start}-{abs(hash(title)) % 100000}'), 'title': title,
            'location': str(raw.get('location') or '').strip(), 'start': start, 'end': end,
            'all_day': bool(raw.get('all_day'))}


def migrate(state):
    """Old single-event calendar ({title, location, minutes, duration, pushed_at}) → events list."""
    if not state:
        return []
    if 'events' in state:
        return state['events']
    if state.get('title'):
        start = int(state.get('pushed_at', time.time()) + int(state.get('minutes', 0)) * 60)
        return [{'id': 'migrated', 'title': state['title'], 'location': state.get('location', ''),
                 'start': start, 'end': start + int(state.get('duration', 60)) * 60, 'all_day': False}]
    return []
