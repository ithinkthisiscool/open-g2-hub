"""Notifications (SID 0x04 control + file service EFS) — spec: docs/research/file_service_notifications.md."""
import asyncio

from aiohttp import web

from g2 import evenhub as eh
from g2 import file_service as fsp
from hub import state, sync
from hub.events import on_event


async def send_efs_file(session, file_type, data):
    return await fsp.send_file(session, file_type, data,
                               log=lambda msg, ok: on_event(msg, level='ok' if ok else 'warn'))


async def setup(session, disp_time=5):
    """SID 0x04: enable notifications + auto-display, and disable the glasses-side whitelist
    (the sync engine's 'notifications' section; the connect sequence sends the same)."""
    magic = session.next_magic()
    pb = fsp.build_notification_ctrl(magic, disp_time=int(disp_time))
    on_event(f'Notification CTRL → enable, auto-display, dispTime={disp_time} pb={pb.hex()}', level='info')
    await session._send_right(eh.frame_pb(pb, fsp.SID_NOTIFICATION, eh.FLAG_REQUEST, session.next_seq()))
    await asyncio.sleep(0.4)
    magic = session.next_magic()
    pb = fsp.build_whitelist_disable(magic)
    on_event(f'Notification whitelist → disabled pb={pb.hex()}', level='info')
    await session._send_right(eh.frame_pb(pb, fsp.SID_NOTIFICATION, eh.FLAG_REQUEST, session.next_seq()))


async def api_notify_setup(request):
    """{disp_time?} → save the display time for this pair and turn notifications on now (sync
    engine 'notifications'). Kept for scripts; the hub does this on every connect anyway."""
    if state.current_session() is None:
        return web.json_response({'error': 'not connected'}, status=503)
    data = await request.json()
    try:
        disp = max(1, min(60, int(data.get('disp_time', 5))))
    except (TypeError, ValueError):
        return web.json_response({'error': 'disp_time must be a number'}, status=400)
    state.save_hub_state('notifications', {'disp_time': disp})
    out = await sync.sync_now('notifications')
    if not out.ok:
        return web.json_response({'error': out.message}, status=502)
    return web.json_response({'ok': True})


async def api_notify_send(request):
    session = state.current_session()
    if session is None:
        return web.json_response({'error': 'not connected'}, status=503)
    data = await request.json()
    payload = fsp.notification_json(
        title=(data.get('title') or 'Hub')[:64], message=(data.get('message') or '')[:512],
        subtitle=(data.get('subtitle') or '')[:64], display_name=(data.get('display_name') or 'Even Realities')[:32])
    on_event(f'Notification → {len(payload)}B JSON via file service', level='info')
    try:
        ok, msg = await send_efs_file(session, fsp.FILE_TYPE_NOTIFICATION, payload)
    except Exception as e:
        ok, msg = False, str(e)
    on_event(f'Notification result: {msg}', level='ok' if ok else 'warn')
    return web.json_response({'ok': ok, 'result': msg}) if ok else web.json_response({'error': msg}, status=502)


ROUTES = [
    ('POST', '/api/notify_setup', api_notify_setup),
    ('POST', '/api/notify_send', api_notify_send),
]
