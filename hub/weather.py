"""Live weather for the glasses' status bar, from Open-Meteo (free, no API key).

Where: a city name (geocoded by Open-Meteo), explicit lat/lon, or — if nothing is set — this
machine's approximate location from its public IP (ip-api.com, free, no key).

What the glasses get (see g2.dashboard.build_weather_push): temperature in whole °C (the unit
setting only changes how the glasses display it), a WeatherType icon 0–16, a short condition
text, a rain hint for the next hours, and the next sunrise/sunset time. All strings ≤ 32 chars.
"""
import time

import aiohttp

# g2.dashboard WeatherType: 0 UNKNOWN 1 SUNNY 2 CLOUDS 3 DRIZZLE 4 HEAVY_DRIZZLE 5 RAIN 6 HEAVY_RAIN
# 7 THUNDERSTORM 8 THUNDER 9 SNOW 10 MIST 11 FOG 12 DUST 13 SQUALLS 14 TORNADO 15 FREEZING_RAIN 16 NIGHT
WEATHER_TYPES = {0: 'Unknown', 1: 'Sunny', 2: 'Cloudy', 3: 'Drizzle', 4: 'Heavy drizzle', 5: 'Rain',
                 6: 'Heavy rain', 7: 'Thunderstorm', 8: 'Thunder', 9: 'Snow', 10: 'Mist', 11: 'Fog',
                 12: 'Dust', 13: 'Squalls', 14: 'Tornado', 15: 'Freezing rain', 16: 'Clear night'}

# WMO weather code (Open-Meteo) → (WeatherType, text)
_WMO = {0: (1, 'Clear'), 1: (1, 'Mostly clear'), 2: (2, 'Partly cloudy'), 3: (2, 'Overcast'),
        45: (11, 'Fog'), 48: (11, 'Freezing fog'), 51: (3, 'Light drizzle'), 53: (3, 'Drizzle'),
        55: (4, 'Heavy drizzle'), 56: (15, 'Freezing drizzle'), 57: (15, 'Freezing drizzle'),
        61: (5, 'Light rain'), 63: (5, 'Rain'), 65: (6, 'Heavy rain'), 66: (15, 'Freezing rain'),
        67: (15, 'Freezing rain'), 71: (9, 'Light snow'), 73: (9, 'Snow'), 75: (9, 'Heavy snow'),
        77: (9, 'Snow grains'), 80: (5, 'Showers'), 81: (5, 'Showers'), 82: (6, 'Heavy showers'),
        85: (9, 'Snow showers'), 86: (9, 'Snow showers'), 95: (7, 'Thunderstorm'),
        96: (7, 'Thunderstorm, hail'), 99: (7, 'Thunderstorm, hail')}

RAIN_PROB_THRESHOLD = 40                        # % chance counted as "rain expected"
REFRESH_S = 15 * 60                             # the official app refreshes every 15 minutes
_TIMEOUT = aiohttp.ClientTimeout(total=15)


async def geocode(city):
    """City name → {name, lat, lon}. Raises LookupError if not found."""
    async with aiohttp.ClientSession(timeout=_TIMEOUT) as s:
        async with s.get('https://geocoding-api.open-meteo.com/v1/search',
                         params={'name': city, 'count': 1, 'language': 'en'}) as r:
            data = await r.json(content_type=None)
    res = (data or {}).get('results') or []
    if not res:
        raise LookupError(f'city not found: {city}')
    top = res[0]
    label = ', '.join(x for x in (top.get('name'), top.get('admin1'), top.get('country_code')) if x)
    return {'name': label, 'lat': top['latitude'], 'lon': top['longitude']}


async def locate_by_ip():
    async with aiohttp.ClientSession(timeout=_TIMEOUT) as s:
        async with s.get('http://ip-api.com/json/?fields=status,city,regionName,countryCode,lat,lon') as r:
            data = await r.json(content_type=None)
    if data.get('status') != 'success':
        raise LookupError('could not locate this machine by IP')
    return {'name': f"{data['city']}, {data['countryCode']}", 'lat': data['lat'], 'lon': data['lon']}


def _hhmm(iso):
    return iso[11:16] if iso and len(iso) >= 16 else ''


async def current(lat, lon):
    """Fetch and convert current conditions. Returns a dict ready for build_weather_push plus a
    human summary: {temp_c, weather_type, status, rain_icon, rain_hint, sunset_select,
    sunset_hint, summary}."""
    params = {'latitude': lat, 'longitude': lon, 'timezone': 'auto', 'forecast_days': 2,
              'current': 'temperature_2m,weather_code,is_day',
              'hourly': 'precipitation_probability', 'daily': 'sunrise,sunset'}
    async with aiohttp.ClientSession(timeout=_TIMEOUT) as s:
        async with s.get('https://api.open-meteo.com/v1/forecast', params=params) as r:
            if r.status != 200:
                raise RuntimeError(f'Open-Meteo HTTP {r.status}')
            d = await r.json(content_type=None)
    cur = d['current']
    wtype, text = _WMO.get(cur.get('weather_code'), (0, 'Unknown'))
    if wtype == 1 and not cur.get('is_day', 1):
        wtype, text = 16, 'Clear night'

    # Rain, in the app's format (app_behaviour_details.md §3): rainfallProbabilityIcon is a 0/1
    # "rain expected" flag; the hint is "Now", "{n}h" (hours until rain, rounded up), "Tmr", or "0%".
    now_iso = cur['time']                      # local time, "YYYY-MM-DDTHH:MM"
    hours, probs = d['hourly']['time'], d['hourly']['precipitation_probability']
    upcoming = [(t, p) for t, p in zip(hours, probs) if t >= now_iso[:13]][:36]
    first_wet = next(((i, t) for i, (t, p) in enumerate(upcoming) if (p or 0) >= RAIN_PROB_THRESHOLD), None)
    rain_icon, rain_hint, rain_text = 0, '0%', 'no rain expected'
    if first_wet is not None:
        i, t = first_wet
        rain_icon = 1
        if i == 0:
            rain_hint, rain_text = 'Now', 'rain now'
        elif t[:10] != now_iso[:10] and i >= 24 - int(now_iso[11:13]):
            rain_hint, rain_text = 'Tmr', 'rain tomorrow'
        else:
            rain_hint, rain_text = f'{i}h', f'rain in {i} h'

    # Next sunrise/sunset: sunsetSelect 0 = sunrise next, 1 = sunset next; hint is "H:mm" or "-".
    events = sorted([(t, 0) for t in d['daily']['sunrise']] + [(t, 1) for t in d['daily']['sunset']])
    nxt = next(((t, kind) for t, kind in events if t > now_iso), None)
    sunset_select, sunset_hint, sun_text = 1, '-', ''
    if nxt:
        sunset_select = nxt[1]
        sunset_hint = _hhmm(nxt[0]).lstrip('0') or '0:00'
        if sunset_hint.startswith(':'):
            sunset_hint = '0' + sunset_hint
        sun_text = f"{'sunset' if nxt[1] else 'sunrise'} {sunset_hint}"

    temp_c = round(cur['temperature_2m'])
    temp_f = round(temp_c * 9 / 5 + 32)
    return {'temp_c': temp_c, 'weather_type': wtype, 'status': text[:32], 'rain_icon': rain_icon,
            'rain_hint': rain_hint, 'sunset_select': sunset_select, 'sunset_hint': sunset_hint,
            'fetched_at': int(time.time()),
            'summary': f'{temp_c}°C / {temp_f}°F {text.lower()}; {rain_text}; {sun_text}'}
