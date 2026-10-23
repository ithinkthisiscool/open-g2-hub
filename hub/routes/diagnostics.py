"""Connection doctor (GET /api/doctor) and the redacted support bundle (GET /api/diagnostics).

(/api/health is already the glasses health widget, so the doctor lives at /api/doctor.)
Everything here is best effort and read-only; no secrets (API token, keys) are ever returned.
"""
import asyncio
import json
import os
import platform
import shutil
import sys

from aiohttp import web

from hub import auth, paths, power, state
from hub.logs import redact

try:
    from hub.version import __version__
except Exception:
    __version__ = "dev"

LOG_TAIL_LINES = 30
HINTS = {
    'no_adapter': 'No Bluetooth adapter was found on this computer. Plug in a Bluetooth adapter or enable it in your BIOS.',
    'bluetooth_off': 'Bluetooth is turned off. Turn it on in your system settings and the hub will reconnect.',
    'no_pair_saved': 'No glasses are saved yet. Open Glasses and choose Find glasses, or follow the setup guide on Home.',
    'in_case_or_held': 'The glasses are not answering: they may be in their case, out of range, or connected to the phone app. Take them out and close the phone app.',
    'reconnecting': 'The link was just lost; the hub is trying to reconnect.',
    'paused_suspend': 'The computer is suspended or going to sleep; the hub reconnects when it wakes.',
    'paused_adapter': 'Bluetooth was switched off; the hub reconnects when it is turned back on.',
}


def has_adapter():
    """True if the kernel lists a Bluetooth controller (cheap, no subprocess)."""
    try:
        return any(n.startswith('hci') for n in os.listdir('/sys/class/bluetooth'))
    except OSError:
        return False


def pair_saved():
    """True if the database has a pair with both lens addresses."""
    try:
        return any(d['right_mac'] and d['left_mac'] for d in state.STORE.devices())
    except Exception:
        return False


def classify(link, reasons, adapter_present=True, pair=True, adapter_powered=None):
    """(cause, hint) for a not-connected link, or (None, None) when connected/disabled."""
    if link in ('connected', 'disabled'):
        return None, None
    if not adapter_present:
        cause = 'no_adapter'
    elif adapter_powered is False:
        cause = 'bluetooth_off'
    elif link == 'paused':
        cause = 'paused_suspend' if 'sleep' in reasons else 'paused_adapter'
    elif not pair:
        cause = 'no_pair_saved'
    elif link == 'reconnecting':
        cause = 'reconnecting'
    else:
        cause = 'in_case_or_held'
    return cause, HINTS[cause]


def _key_present(name):
    try:
        from hub import even_ai_assistant as eai
        return bool(eai.get_key(name))
    except Exception:
        return False


async def _adapter_powered():
    try:
        return await power._busctl_adapter_powered()
    except Exception:
        return None


def _check(name, ok, detail, hint=''):
    return {'name': name, 'ok': bool(ok), 'detail': detail, 'hint': '' if ok else hint}


async def api_doctor(request):
    """{ok, version, checks: [{name, ok, detail, hint}]}; hint is empty when the check passes."""
    present = has_adapter()
    powered = await _adapter_powered() if present else None
    checks = []
    if not present:
        checks.append(_check('bluetooth_adapter', False, 'no adapter found', HINTS['no_adapter']))
    elif powered is False:
        checks.append(_check('bluetooth_adapter', False, 'adapter present but powered off', HINTS['bluetooth_off']))
    else:
        checks.append(_check('bluetooth_adapter', True, 'adapter present and powered on' if powered else
                             'adapter present (power state unknown)'))
    checks.append(_check('glasses_saved', pair_saved(), 'a pair is saved' if pair_saved() else 'no pair saved',
                         HINTS['no_pair_saved']))
    from hub.routes import core      # lazy: core registers this module's routes
    link, reasons = core.link_state()
    cause, hint = classify(link, reasons, present, pair_saved(), powered)
    checks.append(_check('glasses_connected', link == 'connected', f'link: {link}',
                         hint or 'Not connected right now.'))
    for label, env in (('anthropic_key', 'ANTHROPIC_API_KEY'), ('deepgram_key', 'DEEPGRAM_API_KEY')):
        ok = _key_present(env)
        checks.append(_check(label, ok, 'set' if ok else 'not set',
                             f'Even AI needs {env}. Add it in Settings > Even AI keys.'))
    tok = bool(state.TOKEN) or bool(auth.get_token(create=False))
    checks.append(_check('web_token', tok, 'configured' if tok else 'missing',
                         'The local API token is missing; restart the hub to create it.'))
    return web.json_response({'ok': all(c['ok'] for c in checks), 'version': __version__, 'checks': checks})


def log_tail(n=LOG_TAIL_LINES):
    """Last n lines of the hub log, redacted. [] if unreadable."""
    try:
        with open(paths.log_path(), 'rb') as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - 64 * 1024))
            data = f.read().decode('utf-8', 'replace')
    except OSError:
        return []
    return [redact(line) for line in data.splitlines()[-n:]]


async def _bluez_version():
    exe = shutil.which('bluetoothctl')
    if not exe:
        return None
    try:
        proc = await asyncio.create_subprocess_exec(exe, '--version', stdout=asyncio.subprocess.PIPE,
                                                    stderr=asyncio.subprocess.DEVNULL)
        out, _ = await asyncio.wait_for(proc.communicate(), 3.0)
        return out.decode().strip() or None
    except Exception:
        return None


def _recent_transitions(n=15):
    """Recent connection-related UI events (already redacted)."""
    try:
        from hub.events import history
        rows = [e for e in list(history) if isinstance(e, dict) and
                any(w in str(e.get('msg', e.get('message', ''))).lower() for w in ('connect', 'disconnect', 'link', 'reconnect'))]
        return [redact(json.dumps(e, default=str)) for e in rows[-n:]]
    except Exception:
        return []


async def build_bundle():
    present = has_adapter()
    powered = await _adapter_powered() if present else None
    from hub.routes import core      # lazy: core registers this module's routes
    link, reasons = core.link_state()
    cause, hint = classify(link, reasons, present, pair_saved(), powered)
    return {
        'version': __version__,
        'python': sys.version.split()[0],
        'platform': platform.platform(),
        'adapter': {'present': present, 'powered': powered},
        'bluez': await _bluez_version(),
        'link': {'state': link, 'paused': reasons, 'connected': bool(state.context.get('connected')),
                 'cause': cause, 'hint': hint},
        'pair_saved': pair_saved(),
        'keys': {'anthropic': _key_present('ANTHROPIC_API_KEY'), 'deepgram': _key_present('DEEPGRAM_API_KEY')},
        'recent_link_events': _recent_transitions(),
        'log_tail': log_tail(),
    }


def render_text(b):
    lines = [f'G2 Hub diagnostics', f'version: {b["version"]}', f'python: {b["python"]}', f'platform: {b["platform"]}',
             f'bluetooth adapter: present={b["adapter"]["present"]} powered={b["adapter"]["powered"]}',
             f'bluez: {b["bluez"]}', f'link: {b["link"]["state"]} paused={b["link"]["paused"]} '
             f'cause={b["link"]["cause"]}', f'pair saved: {b["pair_saved"]}',
             f'keys set: anthropic={b["keys"]["anthropic"]} deepgram={b["keys"]["deepgram"]}',
             '', '-- recent link events --', *b['recent_link_events'], '', f'-- log (last {LOG_TAIL_LINES} lines) --',
             *b['log_tail']]
    return redact('\n'.join(lines)) + '\n'


async def api_diagnostics(request):
    """Redacted support bundle. text/plain by default; ?format=json for JSON."""
    b = await build_bundle()
    if request.query.get('format') == 'json':
        return web.json_response(json.loads(redact(json.dumps(b))))
    return web.Response(text=render_text(b), content_type='text/plain', headers={'Cache-Control': 'no-store'})


ROUTES = [
    ('GET', '/api/doctor', api_doctor),
    ('GET', '/api/diagnostics', api_diagnostics),
]
