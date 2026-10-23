"""A small ring buffer of recent frames to and from the glasses, for Report a problem
(hub/report.py). Incoming frames come from hub.frames.on_device_frame; outgoing ones from a thin
wrapper around the session's two write methods (tap_session), so nothing in the g2 library
changes. Only the SID, direction, sizes and the payload bytes are kept; hub/report.py decides
what of the payload may leave this computer."""
import time
from collections import deque

MAX_FRAMES = 200

frames = deque(maxlen=MAX_FRAMES)     # {'ts', 'dir': 'rx'|'tx', 'lens', 'sid', 'packets', 'pb': bytes}


def record(direction, sid, pb, lens='right', packets=1):
    frames.append({'ts': time.time(), 'dir': direction, 'lens': lens, 'sid': int(sid) & 0xFF,
                   'packets': packets, 'pb': bytes(pb or b'')})


def record_tx(lens, packets):
    """`packets`: the list of BLE writes of one message (g2 framing: AA 21 seq len total num sid
    flag + chunk; the last 2 bytes of the joined chunks are the CRC)."""
    pk = [bytes(p) for p in packets or []]
    if not pk:
        return
    if all(len(p) >= 8 and p[0] == 0xAA for p in pk) and len({p[6] for p in pk}) == 1:
        body = b''.join(p[8:8 + p[3]] for p in pk)
        record('tx', pk[0][6], body[:-2] if len(body) >= 2 else body, lens, len(pk))
    else:                                    # file-service framing or something unknown
        sid = pk[0][6] if len(pk[0]) > 6 else 0
        record('tx', sid, b''.join(pk), lens, len(pk))


def tap_session(session):
    """Wrap session._send_right / _send_left so every outgoing message is recorded too. The
    session's own request helpers call these, so acks and pushes are both covered."""
    for lens in ('right', 'left'):
        name = f'_send_{lens}'
        orig = getattr(session, name, None)
        if orig is None or getattr(orig, '_g2hub_tap', False):
            continue

        async def wrapped(packets, *a, _orig=orig, _lens=lens, **kw):
            try:
                record_tx(_lens, packets)
            except Exception:
                pass
            return await _orig(packets, *a, **kw)
        wrapped._g2hub_tap = True
        setattr(session, name, wrapped)
    return session


def clear():
    frames.clear()
