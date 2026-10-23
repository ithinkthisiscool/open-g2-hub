"""Glasses settings (g2/settings.py) — saved per pair and restored on connect — plus the hub-wide
"keep connected when the lid closes" option (hub/hubconfig.py, applied by hub/power.py)."""
import asyncio
import os
from pathlib import Path

from aiohttp import web

from g2 import device
from g2 import settings as gset
from hub import auth, hubconfig, paths, state, sync
from hub.events import on_event
from hub.glasses import send_framed

SETTING_KEYS = ('brightness', 'auto_brightness', 'silent_mode', 'wear_detection', 'head_up',
                'head_up_angle', 'display_timeout', 'language')
HUB_KEYS = tuple(hubconfig.DEFAULTS)

# Set by hub.app: called with the new hub config after a change (hub.power applies it).
on_hub_config_changed = None


def settings_payloads(session, s):
    """(sid, payload, label) for each setting present in dict `s`. Raises ValueError on bad input."""
    out = []
    m = session.next_magic
    if s.get('auto_brightness') is not None:
        out.append((gset.SID, gset.build_auto_brightness(m(), bool(s['auto_brightness'])), 'auto brightness'))
    if s.get('brightness') is not None and not s.get('auto_brightness'):
        out.append((gset.SID, gset.build_brightness(m(), int(s['brightness'])), f'brightness {s["brightness"]}'))
    if s.get('silent_mode') is not None:
        out.append((gset.SID, gset.build_silent_mode(m(), bool(s['silent_mode'])), 'silent mode'))
    if s.get('wear_detection') is not None:
        out.append((gset.SID, gset.build_wear_detection(m(), bool(s['wear_detection'])), 'wear detection'))
    if s.get('head_up') is not None:
        angle = int(s['head_up_angle']) if s.get('head_up_angle') is not None else None
        out.append((gset.SID, gset.build_head_up(m(), bool(s['head_up']), angle), 'head-up'))
    if s.get('display_timeout') is not None:
        t = s['display_timeout']
        out.append((gset.SID_MODULE, gset.build_display_timeout(m(), t if t == 'never' else int(t)),
                    f'display timeout {t}'))
    if s.get('language') is not None:
        out.append((gset.SID_MODULE, gset.build_language(m(), int(s['language'])),
                    f'language {gset.LANGUAGES.get(int(s["language"]))}'))
    return out


async def apply_settings(session, s):
    for sid, payload, label in settings_payloads(session, s):
        await send_framed(session, sid, payload)
        on_event(f'Settings → {label} pb={payload.hex()}', level='info')
        await asyncio.sleep(0.2)


def short_home(path):
    """`path` as text with the home directory written as ~ (for display only)."""
    p, home = str(path), str(Path.home())
    return '~' + p[len(home):] if home not in ('', '/') and (p == home or p.startswith(home + '/')) else p


def hub_files():
    """Where this hub keeps its files (shown in Settings > Hub and files). Paths only, no contents."""
    return {'config_dir': short_home(paths.config_dir()), 'env_file': short_home(paths.env_files()[0]),
            'token_file': short_home(auth.token_path()), 'hub_config': short_home(hubconfig.path()),
            'data_dir': short_home(paths.data_dir()), 'log_file': short_home(paths.log_path())}


def _apply_hub_changes(data):
    changes = {k: data[k] for k in HUB_KEYS if k in data}
    if not changes:
        return None
    cfg = hubconfig.save(changes)
    on_event(f'Hub settings → {changes}', level='ok')
    if on_hub_config_changed is not None:
        on_hub_config_changed(cfg)
    return cfg


class _Magic:
    """Stand-in session for validating settings without glasses (settings_payloads only calls
    next_magic)."""
    def next_magic(self):
        return 1


def validate_settings(changes):
    """Raise ValueError when a value cannot be encoded (same checks as the push)."""
    settings_payloads(_Magic(), changes)


async def api_settings(request):
    """GET → saved settings for this pair + live status + hub settings + sync status. POST
    {brightness, auto_brightness, …, keep_connected_lid_closed, wait?} → save the given glasses
    settings for this pair (only keys present change; works offline) and let the sync engine send
    them; hub keys are saved at once. wait (the API default) + connected: sent now, with the
    result; the web page sends wait=false (debounced)."""
    dev = state.active_device_id()
    if request.method == 'GET':
        return web.json_response({'saved': state.STORE.get(dev, 'settings', {}) if dev else {},
                                  'status': state.context.get('glasses_status') or (state.STORE.get(dev, '_glasses_status', {}) if dev else {}),
                                  'languages': gset.LANGUAGES, 'timeouts': list(gset.TIMEOUT_CHOICES[:-1]) + ['never'],
                                  'brightness_range': [gset.BRIGHTNESS_MIN, gset.BRIGHTNESS_MAX],
                                  'hub': hubconfig.load(), 'files': hub_files(), 'sync': sync.status('settings')})
    data = await request.json()
    if not isinstance(data, dict):
        return web.json_response({'error': 'JSON object required'}, status=400)
    hub_cfg = _apply_hub_changes(data)
    changes = {k: data[k] for k in SETTING_KEYS if k in data}
    if hub_cfg is not None and not changes:
        return web.json_response({'hub': hub_cfg})
    if dev is None:
        return web.json_response({'error': 'no glasses selected'}, status=409)
    try:
        validate_settings(changes)
    except (ValueError, TypeError) as e:
        return web.json_response({'error': str(e)}, status=400)
    saved = {**(state.STORE.get(dev, 'settings', {}) or {}), **changes}
    state.STORE.set(dev, 'settings', saved)
    out = await sync.save_and_sync('settings', data.get('wait', True) is not False)
    body = {'saved': saved, 'sync': sync.status('settings'), **({'hub': hub_cfg} if hub_cfg is not None else {})}
    if out is not None:
        body['ok'] = out.ok
    elif not sync.connected():
        body['note'] = 'saved; will sync when the glasses connect'
    return web.json_response(body)


async def api_glasses_refresh(request):
    """Ask the glasses for their current settings, wear status, case battery and screen-off time."""
    session = state.current_session()
    if session is None:
        return web.json_response({'error': 'not connected'}, status=503)
    for sid, build in ((gset.SID, gset.build_read_settings), (device.SID_ONBOARDING, device.build_wear_status_query),
                       (device.SID_CASE, device.build_case_info_query), (gset.SID_MODULE, gset.build_read_display_timeout)):
        await send_framed(session, sid, build(session.next_magic()))
        await asyncio.sleep(0.15)
    return web.json_response({'ok': True})


async def api_device_restart(request):
    """Reboot the glasses (0x80 cmd 15, DECODED/untested). The link drops and the hub reconnects."""
    session = state.current_session()
    if session is None:
        return web.json_response({'error': 'not connected'}, status=503)
    await send_framed(session, device.SID, device.build_quick_restart(session.next_magic()))
    on_event('Device → QUICK_RESTART sent; expect the link to drop and reconnect', level='warn')
    return web.json_response({'ok': True})

KEY_ENV = {'anthropic': 'ANTHROPIC_API_KEY', 'deepgram': 'DEEPGRAM_API_KEY'}


def save_env_keys(updates):
    """Merge {ENV_NAME: value} into ~/.config/g2hub/.env (0600), leaving every other line alone."""
    path = paths.env_files()[0]
    try:
        lines = path.read_text().splitlines()
    except OSError:
        lines = []
    pending = dict(updates)
    for i, line in enumerate(lines):
        name = line.split('=', 1)[0].strip()
        if '=' in line and not line.lstrip().startswith('#') and name in pending:
            lines[i] = f'{name}={pending.pop(name)}'
    lines += [f'{k}={v}' for k, v in pending.items()]
    paths.ensure_dir(path.parent)
    tmp = Path(str(path) + f'.{os.getpid()}.tmp')
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        f.write('\n'.join(lines) + '\n')
    os.replace(tmp, path)
    os.chmod(path, 0o600)


async def api_keys(request):
    """POST {anthropic?, deepgram?} → save the given keys to the .env file (others untouched).
    Returns only {anthropic_set, deepgram_set[, note]}; a key is never echoed."""
    data = await request.json()
    if not isinstance(data, dict):
        return web.json_response({'error': 'JSON object required'}, status=400)
    updates, notes = {}, []
    for field, env_name in KEY_ENV.items():
        val = data.get(field)
        if val is None:
            continue
        if not isinstance(val, str):
            return web.json_response({'error': f'{field} must be a string'}, status=400)
        val = val.strip()
        if not val:
            continue
        if any(c in val for c in '\r\n\0') or ' ' in val:
            return web.json_response({'error': f'{field} key contains invalid characters'}, status=400)
        if field == 'anthropic' and not val.startswith('sk-ant-'):
            notes.append('That Anthropic key does not start with sk-ant-; saved anyway, double-check it.')
        updates[env_name] = val
    if updates:
        try:
            save_env_keys(updates)
        except OSError as e:
            return web.json_response({'error': f'could not write the key file: {e.strerror}'}, status=500)
        on_event(f'Keys → saved {", ".join(sorted(updates))}', level='ok')
    from hub import even_ai_assistant as eai
    out = {'anthropic_set': bool(eai.get_key('ANTHROPIC_API_KEY')), 'deepgram_set': bool(eai.get_key('DEEPGRAM_API_KEY'))}
    if notes:
        out['note'] = ' '.join(notes)
    return web.json_response(out)


ROUTES = [
    ('POST', '/api/keys', api_keys),
    ('GET', '/api/settings', api_settings),
    ('POST', '/api/settings', api_settings),
    ('POST', '/api/glasses/refresh', api_glasses_refresh),
    ('POST', '/api/device/restart', api_device_restart),
]
