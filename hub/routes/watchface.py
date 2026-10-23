"""Watchface layout (SID 0x1f): EXPERIMENTAL, never seen on the glasses.

"Read" asks the glasses which layout file they hold (cmd 0 -> cmd 1); it changes nothing.
"Upload" replaces the layout. g2/watchface.py warns that a bad file may leave the dashboard blank
until a valid one is uploaded, so the route needs confirm="UPLOAD" and remembers what the glasses
had before. Replies from the glasses arrive through hub/frames.py -> on_frame()."""
import asyncio
import time

from aiohttp import web

from g2 import evenhub as eh
from g2 import watchface as wf
from hub import state
from hub.events import on_event

COMPONENTS = {'none': wf.COMP_NONE, 'temperature': wf.COMP_TEMPERATURE, 'sunset': wf.COMP_SUNSET,
              'next_rain': wf.COMP_NEXTRAIN, 'notification': wf.COMP_NOTIFICATION,
              'heart_rate': wf.COMP_HEARTRATE, 'steps': wf.COMP_STEPS, 'calories': wf.COMP_CALORIES,
              'blood_oxygen': wf.COMP_BLOOD_OXYGEN, 'sleep': wf.COMP_SLEEP}
POSITIONS = {'left': wf.POS_LEFT, 'center': wf.POS_CENTER, 'right': wf.POS_RIGHT}
REPLY_TIMEOUT_S = 6.0
CONFIRM_WORD = 'UPLOAD'

_waiters = {}            # cmd -> list of futures waiting for that reply
_last = {}               # last reply per cmd, for the UI


def on_frame(pb):
    """Called by hub/frames.py for every SID 0x1f frame (inside the BLE callback: no awaits)."""
    d = wf.decode(pb)
    d.pop('data', None)
    _last[d['cmd']] = {**d, 'at': int(time.time())}
    on_event(f'Watchface ← {d["name"]} {({k: v for k, v in d.items() if k not in ("cmd", "name", "magic")})}',
             level='info')
    for fut in _waiters.pop(d['cmd'], []):
        if not fut.done():
            fut.set_result(d)


async def _send(session, payload, magic, label):
    frames = eh.frame_pb(payload, wf.SID, eh.FLAG_REQUEST, session.next_seq())
    await session._send_right(frames)
    on_event(f'Watchface → {label} (magic {magic})', level='info')


async def _wait(cmds, timeout=REPLY_TIMEOUT_S):
    """Wait for the first reply whose cmd is in `cmds`. Returns the decoded reply or None."""
    loop = asyncio.get_running_loop()
    futs = []
    for c in cmds:
        f = loop.create_future()
        _waiters.setdefault(c, []).append(f)
        futs.append(f)
    try:
        done, _ = await asyncio.wait(futs, timeout=timeout, return_when=asyncio.FIRST_COMPLETED)
        return next(iter(done)).result() if done else None
    finally:
        for c, f in zip(cmds, futs):
            if f in _waiters.get(c, []):
                _waiters[c].remove(f)


async def read_info(session):
    magic = session.next_magic()
    waiting = asyncio.ensure_future(_wait([wf.CMD_INFO_RESPONSE]))
    await asyncio.sleep(0)
    await _send(session, wf.build_info_request(magic), magic, 'REQUEST_INFO')
    return await waiting


def build_layout(cfg):
    """cfg {style: 1|3, left, right, pos, date, temp} -> layout file bytes (version = a time stamp).
    date/temp (default on) only apply to style 3."""
    version = str(int(time.time()))
    pos = POSITIONS[cfg.get('pos', 'center')]
    if int(cfg.get('style', 1)) == 3:
        number, layout = 3, wf.encode_layout3(0, int(bool(cfg.get('date', True))), int(bool(cfg.get('temp', True))))
    else:
        number = 1
        layout = wf.encode_layout1(0, COMPONENTS[cfg.get('left', 'temperature')],
                                   COMPONENTS[cfg.get('right', 'sunset')])
    body = wf.build_layout_file(version, '', number, layout, pos)
    return wf.build_layout_file(version, eh.crc16_ccitt(body).hex(), number, layout, pos)


async def upload(session, file_bytes):
    """REQUEST_UPGRADE → (UPGRADE_RESPONSE / TRANSMIT_START) → FILE_DATA per fragment, each acked →
    UPDATE_SUCCESS. Returns (ok, steps)."""
    steps = []
    magic = session.next_magic()
    waiting = asyncio.ensure_future(_wait([wf.CMD_TRANSMIT_START, wf.CMD_UPGRADE_RESPONSE]))
    await asyncio.sleep(0)
    await _send(session, wf.build_upgrade_request(magic), magic, 'REQUEST_UPGRADE')
    r = await waiting
    if r is None:
        return False, steps + ['no answer to the upgrade request']
    steps.append(f'{r["name"]} {r.get("status", r.get("value", ""))}')
    if r['cmd'] == wf.CMD_UPGRADE_RESPONSE:
        if r.get('status'):
            return False, steps + ['glasses refused the upgrade']
        r = await _wait([wf.CMD_TRANSMIT_START])
        if r is None:
            return False, steps + ['no TRANSMIT_START']
        steps.append('TRANSMIT_START')
    # Pre-arm the success waiter BEFORE sending fragments: the glasses can send UPDATE_SUCCESS
    # back-to-back with the final FILE_DATA_ACK (both decoded in the BLE callback), and a waiter
    # registered only afterwards would miss it and time out, falsely reporting failure.
    success = asyncio.ensure_future(_wait([wf.CMD_UPDATE_SUCCESS]))
    await asyncio.sleep(0)
    for payload in wf.build_file_fragments(session.next_magic, file_bytes):
        frag = wf.decode(payload)
        waiting = asyncio.ensure_future(_wait([wf.CMD_FILE_DATA_ACK]))
        await asyncio.sleep(0)
        await _send(session, payload, frag['magic'], f'FILE_DATA {frag["fragment_index"]}')
        ack = await waiting
        if ack is None or ack.get('status'):
            success.cancel()
            return False, steps + [f'fragment {frag["fragment_index"]}: {"no ack" if ack is None else ack}']
        steps.append(f'fragment {frag["fragment_index"]} acked')
    done = await success
    steps.append('UPDATE_SUCCESS' if done else 'no UPDATE_SUCCESS')
    return done is not None, steps


async def api_watchface(request):
    """GET → layout choices + last replies. POST {action: 'read'} → ask the glasses for their layout.
    POST {action: 'upload', style, left, right, pos, confirm: 'UPLOAD'} → replace the layout."""
    if request.method == 'GET':
        return web.json_response({'components': list(COMPONENTS), 'positions': list(POSITIONS),
                                  'last': {wf.CMD_NAMES[c]: v for c, v in _last.items()},
                                  'settings': state.load_hub_state().get('watchface') or {}})
    data = await request.json()
    action = data.get('action')
    if action not in ('read', 'upload'):
        return web.json_response({'error': 'action must be read or upload'}, status=400)
    if action == 'upload':
        if data.get('confirm') != CONFIRM_WORD:
            return web.json_response({'error': f'type {CONFIRM_WORD} to confirm the upload'}, status=400)
        cfg = {k: data.get(k) for k in ('style', 'left', 'right', 'pos', 'date', 'temp') if data.get(k) is not None}
        if (cfg.get('left', 'temperature') not in COMPONENTS or cfg.get('right', 'sunset') not in COMPONENTS
                or cfg.get('pos', 'center') not in POSITIONS or int(cfg.get('style', 1)) not in (1, 3)):
            return web.json_response({'error': 'unknown style, component or position'}, status=400)
    session = state.current_session()
    if session is None:
        return web.json_response({'error': 'glasses not connected'}, status=503)
    info = await read_info(session)
    before = {k: info.get(k) for k in ('exists', 'version', 'hash')} if info else None
    if action == 'read':
        return web.json_response({'info': before, 'note': None if info else 'no reply from the glasses'})
    file_bytes = build_layout(cfg)
    ok, steps = await upload(session, file_bytes)
    state.save_hub_state('watchface', {**cfg, 'before': before, 'uploaded_ok': ok})
    on_event(f'Watchface upload {"done" if ok else "FAILED"}: {"; ".join(steps)}', level='ok' if ok else 'warn')
    return web.json_response({'ok': ok, 'steps': steps, 'before': before, 'file_hex': file_bytes.hex()})


ROUTES = [
    ('GET', '/api/watchface', api_watchface),
    ('POST', '/api/watchface', api_watchface),
]
