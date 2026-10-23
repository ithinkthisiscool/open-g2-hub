"""Real routing for the glasses' Navigation app: geocode (OSM Nominatim) + route (OSRM demo).

PRIVACY: the place names/coordinates you enter are sent to nominatim.openstreetmap.org and
router.project-osrm.org (3rd-party free services, best-effort, no SLA). Nothing else is sent.

NO GPS: a Linux PC has no live position, so the route is a stored step list and the user advances
it manually (POST /api/app/navigation/step); it does NOT advance as you move.
"""
import asyncio
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta

from hub.version import __version__

NOMINATIM = 'https://nominatim.openstreetmap.org/search'
OSRM = 'https://router.project-osrm.org/route/v1/driving/{lon1},{lat1};{lon2},{lat2}'
USER_AGENT = f'g2hub/{__version__} (Even G2 hub navigation; personal use)'
MIN_INTERVAL_S = 1.0                       # Nominatim usage policy: max 1 request/second
TIMEOUT_S = 10

ACTIVE = None        # {'from','to','steps':[...],'index':int} while a route is loaded
_last_call = 0.0
_lock = None


class RoutingError(Exception):
    """Friendly, user-facing failure (network down, no result, bad input)."""


def clear():
    global ACTIVE
    ACTIVE = None


def _get_json(url):
    req = urllib.request.Request(url, headers={'User-Agent': USER_AGENT, 'Accept': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_S) as r:
            return json.loads(r.read().decode('utf-8'))
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise RoutingError(f'routing service unreachable ({e}); live routing needs internet access '
                           f'to nominatim.openstreetmap.org and router.project-osrm.org') from e


async def _polite_get(url):
    """Fetch JSON in a thread, serialising calls and keeping >= 1 s between them."""
    global _last_call, _lock
    if _lock is None:
        _lock = asyncio.Lock()
    async with _lock:
        wait = MIN_INTERVAL_S - (time.monotonic() - _last_call)
        if wait > 0:
            await asyncio.sleep(wait)
        try:
            return await asyncio.get_running_loop().run_in_executor(None, _get_json, url)
        finally:
            _last_call = time.monotonic()


_LATLON = re.compile(r'^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*$')


async def geocode(place):
    """place -> (lat, lon, display_name). Accepts a literal "lat,lon" without any network call."""
    place = (place or '').strip()
    if not place:
        raise RoutingError('place required')
    m = _LATLON.match(place)
    if m:
        lat, lon = float(m.group(1)), float(m.group(2))
        if abs(lat) > 90 or abs(lon) > 180:
            raise RoutingError(f'invalid coordinates: {place}')
        return lat, lon, f'{lat:.5f}, {lon:.5f}'
    url = NOMINATIM + '?' + urllib.parse.urlencode({'format': 'json', 'limit': 1, 'q': place})
    data = await _polite_get(url)
    if not isinstance(data, list) or not data:
        raise RoutingError(f'no match found for "{place}"')
    try:
        hit = data[0]
        return float(hit['lat']), float(hit['lon']), str(hit.get('display_name') or place)
    except (KeyError, TypeError, ValueError) as e:
        raise RoutingError(f'unexpected geocoder reply for "{place}"') from e


def parse_osrm(data):
    """OSRM route JSON -> [{maneuver, road, distance_m, duration_s}, ...]. `maneuver` is a
    'type[:modifier]' string (e.g. 'turn:left', 'depart', 'arrive'); distance/duration are for the
    leg of road that FOLLOWS the maneuver."""
    if not isinstance(data, dict) or data.get('code') != 'Ok' or not data.get('routes'):
        raise RoutingError('no route found between those places')
    steps = []
    for leg in data['routes'][0].get('legs', []):
        for s in leg.get('steps', []):
            man = s.get('maneuver') or {}
            kind = man.get('type') or 'continue'
            mod = man.get('modifier')
            steps.append({'maneuver': f'{kind}:{mod}' if mod else kind,
                          'road': s.get('name') or '',
                          'distance_m': float(s.get('distance') or 0),
                          'duration_s': float(s.get('duration') or 0)})
    if not steps:
        raise RoutingError('route has no steps')
    return steps


async def route(from_latlon, to_latlon):
    """(lat, lon) x2 -> step list (see parse_osrm)."""
    url = OSRM.format(lat1=from_latlon[0], lon1=from_latlon[1], lat2=to_latlon[0], lon2=to_latlon[1])
    data = await _polite_get(url + '?' + urllib.parse.urlencode({'steps': 'true', 'overview': 'false'}))
    return parse_osrm(data)


# ── formatting for the glasses ────────────────────────────────────────────────────────────────
def fmt_distance(m):
    m = float(m)
    return f'{int(round(m, -1)) if m >= 20 else int(round(m))} m' if m < 1000 else f'{m / 1000:.1f} km'


def fmt_duration(s):
    mins = max(1, int(round(float(s) / 60)))
    return f'{mins} min' if mins < 60 else f'{mins // 60} h {mins % 60:02d} min'


def direction_for(maneuver):
    """OSRM 'type:modifier' -> g2.navigation DIRECTION name."""
    kind, _, mod = maneuver.partition(':')
    if kind == 'depart':
        return 'DEPART'
    if kind in ('roundabout', 'rotary', 'roundabout turn'):
        return 'ROUNDABOUT_CW'
    return {'right': 'TURN_RIGHT', 'left': 'TURN_LEFT', 'slight right': 'TURN_SLIGHT_RIGHT',
            'slight left': 'TURN_SLIGHT_LEFT', 'sharp right': 'TURN_SHARP_RIGHT',
            'sharp left': 'TURN_SHARP_LEFT', 'uturn': 'UTURN_COUNTERCLOCKWISE'}.get(mod, 'STRAIGHT')


def step_fields(steps, i, now=None):
    """Glasses fields for steps[i]: direction, distance TO this maneuver (the previous step's
    leg), road, remaining distance/time and ETA."""
    now = now or datetime.now()
    s = steps[i]
    to_here = steps[i - 1]['distance_m'] if i > 0 else None
    rem_m = sum(x['distance_m'] for x in steps[i:])
    rem_s = sum(x['duration_s'] for x in steps[i:])
    return {'direction': direction_for(s['maneuver']),
            'distance': fmt_distance(to_here) if to_here is not None else None,
            'road': s['road'] or None,
            'remaining_distance': fmt_distance(rem_m),
            'remaining_time': fmt_duration(rem_s),
            'eta': (now + timedelta(seconds=rem_s)).strftime('%H:%M')}


def load(src, dst, steps):
    global ACTIVE
    ACTIVE = {'from': src, 'to': dst, 'steps': steps, 'index': -1}


def next_index():
    """Advance the loaded route; returns the new step index or None if no route / already at end."""
    if not ACTIVE or ACTIVE['index'] + 1 >= len(ACTIVE['steps']):
        return None
    ACTIVE['index'] += 1
    return ACTIVE['index']
