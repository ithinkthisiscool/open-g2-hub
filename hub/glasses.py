"""Small helpers shared by every feature that talks to the glasses session."""
import asyncio

from aiohttp import web

from g2 import device
from g2 import evenhub as eh

FLAG_NAMES = {0: 'DASHBOARD_RECEIVED_SUCCESS', 1: 'DASHBOARD_PARAMETER_ERROR', 2: 'DASHBOARD_NEWS_VERSION_ERROR'}


def not_connected():
    return web.json_response({'error': 'not connected'}, status=503)


def decode_dashboard_ack(raw):
    if raw is None:
        return 'no ack'
    cmd = eh.read_varint_field(raw, 1, -1)
    respond = eh.read_bytes_field(raw, 3)
    if respond is not None:  # an empty respond message means flag 0 (protobuf default = success)
        flag = eh.read_varint_field(respond, 2, 0)
        return f'commandId={cmd} flag={flag} ({FLAG_NAMES.get(flag, "?")})'
    return f'commandId={cmd} raw={raw.hex()}'


async def send_framed(session, sid, payload, lens='right'):
    """Frame with the flag the official app uses for this message (device.flag_for) and send."""
    flag = device.flag_for(sid, payload)
    if lens in ('right', 'both'):
        await session._send_right(eh.frame_pb(payload, sid, flag, session.next_seq()))
    if lens in ('left', 'both'):
        await session._send_left(eh.frame_pb(payload, sid, flag, session.next_seq()))


def hub_heartbeat_running(session):
    task = getattr(session, '_hb_task', None)
    return task is not None and not task.done()


def start_hub_heartbeat(session):
    """(Re)start the session's EvenHub heartbeat (SID 0x01 is only acked while it runs).
    Returns True if it was started now. Never restarts it on a session that is closing, so a
    push that is still running after a disconnect cannot leave a heartbeat on a dead link."""
    if getattr(session, '_closing', False) or hub_heartbeat_running(session):
        return False
    session._hb_task = asyncio.ensure_future(session._heartbeat_loop())
    return True


def stop_hub_heartbeat(session):
    """Stop the EvenHub heartbeat (the native dashboard takes over ~5 s later). True if stopped."""
    task = getattr(session, '_hb_task', None)
    if task and not task.done():
        task.cancel()
        session._hb_task = None
        return True
    return False
