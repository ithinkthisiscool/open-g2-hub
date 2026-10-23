"""Developer-section endpoints: news-protocol diagnostics and manual Even AI frames.
The everyday UI sections do not use them; they send low-level frames and are kept for
reverse-engineering sessions. (/api/diag_news and /api/diag_news_id have no button in the page.)"""
import asyncio
import time

from aiohttp import web

from g2 import dashboard as rdp
from g2 import even_ai as ai
from g2 import evenhub as eh
from g2.session import parse_frame
from hub import state
from hub.events import on_event
from hub.glasses import decode_dashboard_ack
from hub.routes import even_ai as eai_routes


async def api_diag_news(request):
    """Binary-search diagnostics to find exactly WHY news V2 (CMD_DASHBOARD_RECEIVE) always returns
    PARAMETER_ERROR while calendar (same structure, different widget type) returns SUCCESS.
    Tries 4 variants and returns all raw ACK bytes:
      A) News V2 standard (rWidgetComponent.news at field 1, display_setting=[WIDGET_NEWS])
      B) News content at field 2 (wrong widget position, to test if field 1 is the issue)
      C) News at field 1 but NO display_setting (probe-style, full content)
      D) V2 FIFO count (cmdId=5) to compare with V3 count we always get=1
    """
    session = state.current_session()
    if session is None:
        return web.json_response({'error': 'not connected'}, status=503)

    results = {}
    rt = int(time.time())
    news_item = rdp.encode_news(1, 'DiagTest', rt, 'Diag', 'Diagnostic test content')

    # V2 FIFO count (cmdId=5, field 7) — compare with V3 count (always 1)
    on_event('diag: V2 FIFO count (cmdId=5)...', level='info')
    magic = session.next_magic()
    payload = rdp.build_news_fifo_count_request(magic)
    raw = await session._send_and_get_payload(rdp.SID_DASHBOARD, eh.FLAG_REQUEST, magic, payload,
                                               session.next_seq(), 'diag V2 fifo', timeout_s=3.0)
    v2_count = None
    if raw:
        resp = eh.read_bytes_field(raw, 8)
        if resp:
            v2_count = eh.read_varint_field(resp, 1, None)
    results['v2_fifo'] = {'raw': raw.hex() if raw else None, 'count': v2_count}
    await asyncio.sleep(0.5)

    # A) News V2 standard: rWidgetComponent.news at field 1, display_setting=[WIDGET_NEWS]
    on_event('diag A: V2 news field=1 + display_setting=[WIDGET_NEWS]...', level='info')
    magic = session.next_magic()
    news_widget = rdp.encode_news_widget([news_item])
    wc_a = eh.encode_message_field(1, news_widget)  # field 1 = news in rWidgetComponent
    content_a = rdp.encode_dashboard_content_widget(wc_a)
    ds_a = rdp.encode_dashboard_display_setting([rdp.WIDGET_NEWS])
    receive_a = rdp.encode_dashboard_receive_from_app(1, content_a, ds_a)
    payload_a = rdp.encode_dashboard_data_package(rdp.CMD_DASHBOARD_RECEIVE, magic, receive_a)
    raw_a = await session._send_and_get_payload(rdp.SID_DASHBOARD, eh.FLAG_REQUEST, magic, payload_a,
                                                 session.next_seq(), 'diag A', timeout_s=3.0)
    results['A_field1_with_setting'] = {'raw': raw_a.hex() if raw_a else None, 'ack': decode_dashboard_ack(raw_a)}
    await asyncio.sleep(0.5)

    # B) News at field 2 (wrong position, test if field 1 causes the error)
    on_event('diag B: V2 news field=2 (wrong) + display_setting=[WIDGET_NEWS]...', level='info')
    magic = session.next_magic()
    wc_b = eh.encode_message_field(2, news_widget)  # field 2 = stock position (wrong for news)
    content_b = rdp.encode_dashboard_content_widget(wc_b)
    receive_b = rdp.encode_dashboard_receive_from_app(1, content_b, ds_a)
    payload_b = rdp.encode_dashboard_data_package(rdp.CMD_DASHBOARD_RECEIVE, magic, receive_b)
    raw_b = await session._send_and_get_payload(rdp.SID_DASHBOARD, eh.FLAG_REQUEST, magic, payload_b,
                                                 session.next_seq(), 'diag B', timeout_s=3.0)
    results['B_field2_with_setting'] = {'raw': raw_b.hex() if raw_b else None, 'ack': decode_dashboard_ack(raw_b)}
    await asyncio.sleep(0.5)

    # C) News at field 1, NO display_setting (probe-style but full content)
    on_event('diag C: V2 news field=1 NO display_setting...', level='info')
    magic = session.next_magic()
    receive_c = rdp.encode_dashboard_receive_from_app(1, content_a, None)
    payload_c = rdp.encode_dashboard_data_package(rdp.CMD_DASHBOARD_RECEIVE, magic, receive_c)
    raw_c = await session._send_and_get_payload(rdp.SID_DASHBOARD, eh.FLAG_REQUEST, magic, payload_c,
                                                 session.next_seq(), 'diag C', timeout_s=3.0)
    results['C_field1_no_setting'] = {'raw': raw_c.hex() if raw_c else None, 'ack': decode_dashboard_ack(raw_c)}
    await asyncio.sleep(0.5)

    # D) Calendar push (baseline, should always succeed)
    on_event('diag D: calendar push (baseline, should succeed)...', level='info')
    magic = session.next_magic()
    payload_d = rdp.build_calendar_push(magic, [(1, 'DiagEvent', '', '12:00-13:00', rt + 3600)])
    raw_d = await session._send_and_get_payload(rdp.SID_DASHBOARD, eh.FLAG_REQUEST, magic, payload_d,
                                                 session.next_seq(), 'diag D cal', timeout_s=3.0)
    results['D_calendar_baseline'] = {'raw': raw_d.hex() if raw_d else None, 'ack': decode_dashboard_ack(raw_d)}

    on_event(f'diag complete: {results}', level='ok')
    return web.json_response(results)


async def api_diag_news_id(request):
    """Test newsId watermark theory: V2 FIFO count (cmdId=5) returned 21930, suggesting the device
    only accepts news items with newsId > that watermark. Try V2 push with newsId=watermark+1 and
    also try V3 push with the same high newsId to see if EITHER starts rendering."""
    session = state.current_session()
    if session is None:
        return web.json_response({'error': 'not connected'}, status=503)
    data = await request.json()
    title = data.get('title', 'NewsIdTest')
    source = data.get('source', 'Diag')
    content = data.get('content', 'Testing newsId watermark theory.')
    rt = int(time.time())

    # Step 1: Get fresh V2 FIFO count (newsId watermark)
    on_event('newsid-diag: V2 FIFO count (watermark query)...', level='info')
    magic = session.next_magic()
    payload = rdp.build_news_fifo_count_request(magic)
    raw = await session._send_and_get_payload(rdp.SID_DASHBOARD, eh.FLAG_REQUEST, magic, payload,
                                               session.next_seq(), 'v2 fifo', timeout_s=3.0)
    watermark = 0
    if raw:
        resp = eh.read_bytes_field(raw, 8)
        if resp:
            watermark = eh.read_varint_field(resp, 1, 0) or 0
    on_event(f'newsid-diag: watermark={watermark}', level='info')
    await asyncio.sleep(0.3)

    results = {'watermark': watermark}

    # Try V2 push with newsId = watermark + 1
    news_id_v2 = watermark + 1
    on_event(f'newsid-diag: V2 push with newsId={news_id_v2}...', level='info')
    magic = session.next_magic()
    news_item = rdp.encode_news(news_id_v2, title, rt, source, content)
    news_widget = rdp.encode_news_widget([news_item], news_total=1, start_index=0)
    wc = eh.encode_message_field(1, news_widget)
    cnt = rdp.encode_dashboard_content_widget(wc)
    ds = rdp.encode_dashboard_display_setting([rdp.WIDGET_NEWS])
    recv = rdp.encode_dashboard_receive_from_app(1, cnt, ds)
    payload = rdp.encode_dashboard_data_package(rdp.CMD_DASHBOARD_RECEIVE, magic, recv)
    raw_v2 = await session._send_and_get_payload(rdp.SID_DASHBOARD, eh.FLAG_REQUEST, magic, payload,
                                                  session.next_seq(), 'v2 news high_id', timeout_s=3.0)
    results['v2_high_id'] = {'newsId': news_id_v2, 'raw': raw_v2.hex() if raw_v2 else None,
                              'ack': decode_dashboard_ack(raw_v2)}
    await asyncio.sleep(0.5)

    # Try V3 push with newsId = watermark + 1 (to test if V3 display also uses watermark)
    on_event(f'newsid-diag: V3 AppSendNewsData with newsId={news_id_v2}...', level='info')
    magic = session.next_magic()
    payload = rdp.build_news_push_v3(magic, news_id=news_id_v2, title=title, report_time=rt,
                                      source=source, content=content,
                                      session_id=0, session_status=0,
                                      session_total_count=1, session_news_index=0)
    raw_v3 = await session._send_and_get_payload(rdp.SID_DASHBOARD, eh.FLAG_REQUEST, magic, payload,
                                                  session.next_seq(), 'v3 news high_id', timeout_s=3.0)
    v3_status = None
    if raw_v3:
        f12 = eh.read_bytes_field(raw_v3, 12)
        if f12:
            v3_status = eh.read_varint_field(f12, 5, 0)
    results['v3_high_id'] = {'newsId': news_id_v2, 'raw': raw_v3.hex() if raw_v3 else None,
                              'newsStatus': v3_status}

    # Extra: probe with all_count=watermark (instead of 1) to see if that changes the response
    on_event(f'newsid-diag: probe with all_count=watermark ({watermark})...', level='info')
    magic = session.next_magic()
    payload_probe_w = rdp.build_news_probe(magic, all_count=watermark, report_time=rt)
    raw_probe_w = await session._send_and_get_payload(rdp.SID_DASHBOARD, eh.FLAG_REQUEST, magic,
                                                       payload_probe_w, session.next_seq(),
                                                       'probe_watermark', timeout_s=3.0)
    results['probe_with_watermark'] = {'all_count': watermark, 'raw': raw_probe_w.hex() if raw_probe_w else None,
                                        'ack': decode_dashboard_ack(raw_probe_w)}
    await asyncio.sleep(0.3)

    # Listen for unsolicited device messages for 5 seconds after push.
    # The device may send DEV_NOTIFY_NEWS_EVENT (cmdId=12) or DEV_REQUEST_NEWS_UPGRADE (cmdId=11)
    # after processing the news item. These might require a response to trigger display.
    on_event('newsid-diag: listening for device notifications for 5s after push...', level='info')
    notifications = []
    deadline = asyncio.get_running_loop().time() + 5.0
    while asyncio.get_running_loop().time() < deadline:
        remaining = deadline - asyncio.get_running_loop().time()
        try:
            rx = await asyncio.wait_for(session.notes.get(), timeout=min(0.1, remaining))
            rx_bytes = bytes(rx)
            parsed = parse_frame(rx_bytes)
            if parsed:
                svc_hi, _, pb = parsed
                cmdId_rx = eh.read_varint_field(pb, 1, -1)
                notifications.append({'sid': hex(svc_hi), 'cmdId': cmdId_rx, 'raw': pb.hex()})
                on_event(f'newsid-diag: device sent SID=0x{svc_hi:02x} cmdId={cmdId_rx} raw={pb.hex()}', level='ok')
        except asyncio.TimeoutError:
            continue
    results['post_push_notifications'] = notifications
    on_event(f'newsid-diag done: {len(notifications)} notifications after push', level='ok' if not notifications else 'info')
    return web.json_response(results)


async def api_ai_config(request):
    """CONFIG (cmd=10): {voice_switch, stream_speed}. The official app sends stream_speed=80 (capture)."""
    session = state.current_session()
    if session is None:
        return web.json_response({'error': 'not connected'}, status=503)
    data = await request.json()
    await eai_routes._ai_send(session, ai.build_config(session.next_magic(), int(data.get('voice_switch', 0)),
                                            int(data.get('stream_speed', ai.DEFAULT_STREAM_SPEED))), 'CONFIG')
    return web.json_response({'ok': True})


async def api_ai_ctrl(request):
    session = state.current_session()
    if session is None:
        return web.json_response({'error': 'not connected'}, status=503)
    data = await request.json()
    await eai_routes.ai_send_ctrl(session, int(data.get('status', eai_routes.AI_CTRL_ENTER)))
    return web.json_response({'ok': True})


async def api_ai_ask(request):
    session = state.current_session()
    if session is None:
        return web.json_response({'error': 'not connected'}, status=503)
    data = await request.json()
    await eai_routes.ai_send_ask(session, (data.get('text') or '')[:400])
    return web.json_response({'ok': True})


async def api_ai_reply(request):
    session = state.current_session()
    if session is None:
        return web.json_response({'error': 'not connected'}, status=503)
    data = await request.json()
    await eai_routes.ai_send_reply(session, (data.get('text') or '')[:4000], int(data.get('chunk_bytes', eai_routes.AI_REPLY_MAX_BYTES)))
    return web.json_response({'ok': True})


ROUTES = [
    ('POST', '/api/diag_news', api_diag_news),
    ('POST', '/api/diag_news_id', api_diag_news_id),
    ('POST', '/api/ai_config', api_ai_config),
    ('POST', '/api/ai_ctrl', api_ai_ctrl),
    ('POST', '/api/ai_ask', api_ai_ask),
    ('POST', '/api/ai_reply', api_ai_reply),
]
