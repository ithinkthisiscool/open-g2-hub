"""Tasks widget (quicklist, SID 0x0c + SID 0x01 display_setting): push, completion ticks from the
glasses, and paging requests."""
import asyncio
from collections import deque

from aiohttp import web

from g2 import dashboard as rdp
from g2 import evenhub as eh
from g2 import quicklist as rqp
from g2.session import parse_frame
from hub import state, sync
from hub.events import notify_state_changed, on_event
from hub.glasses import decode_dashboard_ack, start_hub_heartbeat, stop_hub_heartbeat

_ql_sent_magics = deque(maxlen=64)   # magics of our SID=0x0c pushes; frames echoing them are acks


def load_tasks():
    st = state.load_hub_state().get('quicklist', {})
    return st.get('tasks') or [{'uid': i + 1, 'title': t, 'completed': False}
                               for i, t in enumerate(st.get('items', []))]


def assign_uids(tasks, prev):
    """Give every task a stable uid: keep the ones given, reuse the previous uid of a task with the
    same title, otherwise allocate a new one. The glasses report completion by uid."""
    prev_by_title = {p['title']: p['uid'] for p in prev}
    used = {t['uid'] for t in tasks if t.get('uid')}
    next_uid = max([p['uid'] for p in prev] + list(used) + [0]) + 1
    for t in tasks:
        if not t.get('uid'):
            uid = prev_by_title.get(t['title'])
            if uid is None or uid in used:
                uid, next_uid = next_uid, next_uid + 1
            t['uid'] = uid
            used.add(uid)
    return tasks


def clean_tasks(items):
    """[title | {uid?, title, completed}] -> [{uid?, title, completed}] without blank titles."""
    out = []
    for t in items or []:
        if isinstance(t, str):
            t = {'title': t}
        if not isinstance(t, dict):
            raise ValueError('each task must be a string or {title, completed}')
        uid = t.get('uid')
        title = str(t.get('title', '')).strip()[:200]
        if title:
            out.append({'uid': int(uid) if isinstance(uid, int) and not isinstance(uid, bool) and uid > 0 else None,
                        'title': title, 'completed': bool(t.get('completed'))})
    return out


def save_tasks(items, source=None):
    """Save the task list for the active pair (stable uids) and queue the Tasks sync. Returns it."""
    tasks = clean_tasks(items)
    prev = state.load_hub_state().get('quicklist', {}).get('tasks') or []
    assign_uids(tasks, prev)
    state.save_hub_state('quicklist', {'items': [t['title'] for t in tasks], 'tasks': tasks,
                                       **({'source': source} if source else {})})
    return tasks


async def api_tasks(request):
    """GET -> {tasks, sync}. POST {tasks: [...], wait?} -> save for this pair; the sync engine
    pushes it (wait=true and connected: push now and return the glasses' answer)."""
    if request.method == 'GET':
        return web.json_response({'tasks': load_tasks(), 'sync': sync.status('tasks')})
    data = await request.json()
    if not isinstance(data, dict) or not isinstance(data.get('tasks', []), list):
        return web.json_response({'error': 'tasks must be a list'}, status=400)
    try:
        tasks = save_tasks(data.get('tasks', []))
    except (ValueError, TypeError) as e:
        return web.json_response({'error': str(e)}, status=400)
    notify_state_changed('quicklist')
    out = await sync.save_and_sync('tasks', bool(data.get('wait', False)))
    body = {'tasks': tasks, 'sync': sync.status('tasks')}
    if out is not None:
        body.update(ok=out.ok, result=out.message)
    return web.json_response(body)


async def push_quicklist(titles, save=True):
    """Push the task list and show the tasks widget. Returns (http_status, body). save=False (the
    sync engine) leaves the saved list alone: it may have been edited while this push ran."""
    session = state.current_session()
    if session is None:
        return 503, {'error': 'not connected'}
    if not titles:
        return 400, {'error': 'items required'}
    # Items may be plain titles or {uid?, title, completed}. uids must stay stable per task:
    # the glasses report completion by uid.
    tasks = [{'title': t, 'completed': False} if isinstance(t, str) else
             {'uid': t.get('uid'), 'title': str(t.get('title', '')), 'completed': bool(t.get('completed'))}
             for t in titles]
    tasks = [t for t in tasks if t['title'].strip()]
    prev = state.load_hub_state().get('quicklist', {}).get('tasks') or []
    assign_uids(tasks, prev)
    titles = [t['title'] for t in tasks]
    # App encoding for tasks without a reminder: timestamp=0, tsType=TIME; <=20 per packet.
    items = [(t['uid'], i, t['completed'], 0, t['title'], rqp.TS_TYPE_TIME)
             for i, t in enumerate(tasks)][:rqp.MAX_ITEMS_PER_PACKET]
    on_event(f'quicklist push: {len(titles)} items', level='info')

    # Step 0: Restart heartbeat if stopped (news push stops it; SID=0x01 needs heartbeat active)
    if start_hub_heartbeat(session):
        on_event('quicklist: heartbeat stopped — restarting for SID=0x01 display_setting step', level='info')
        await asyncio.sleep(2)

    # Step 0.5: Dashboard init (display_mode=4, all widgets) — btsnoop confirmed: real app sends
    # this right after connect; re-send here so device re-enters active native dashboard state
    # (especially needed after heartbeat was just restarted from a stopped state).
    on_event('quicklist: dashboard init (display_mode=4)...', level='info')
    magic_init = session.next_magic()
    payload_init = rdp.build_dashboard_init(magic_init)
    raw_init = await session._send_and_get_payload(
        rdp.SID_DASHBOARD, eh.FLAG_REQUEST, magic_init, payload_init,
        session.next_seq(), 'dashboard init', timeout_s=4.0
    )
    init_flag = None
    if raw_init is not None:
        ep = eh.read_bytes_field(raw_init, 3)
        if ep is not None:
            init_flag = eh.read_varint_field(ep, 2, 0)  # field 1 is packageId, field 2 the result flag
    on_event(f'quicklist dashboard init: flag={init_flag}', level='ok' if init_flag == 0 else 'warn')
    await asyncio.sleep(0.3)

    # Step 1: Push task items to SID=0x0c (CORRECTED 2026-09-28: magic in f2, multItems in f4)
    on_event(f'quicklist: pushing {len(titles)} tasks to SID=0x0c: {titles}', level='info')
    ql_data_magic = session.next_magic()
    _ql_sent_magics.append(ql_data_magic)
    payload = rqp.build_quicklist_full_update(items, magic=ql_data_magic)
    frames = eh.frame_pb(payload, rqp.SID_QUICKLIST, eh.FLAG_REQUEST, session.next_seq())
    # Drain stale queue entries before send
    stale = 0
    while not session.notes.empty():
        try:
            session.notes.get_nowait()
            stale += 1
        except Exception:
            break
    if stale:
        on_event(f'quicklist: drained {stale} stale queue entry(s)', level='info')
    await session._send_right(frames)

    # Step 2: Listen 3s for SID=0x0c ack (device echoes cmdId+magic — btsnoop confirmed)
    responses = []
    loop = asyncio.get_running_loop()
    deadline = loop.time() + 3.0
    while loop.time() < deadline:
        remaining = deadline - loop.time()
        try:
            rx = await asyncio.wait_for(session.notes.get(), timeout=max(0.05, remaining))
            parsed = parse_frame(bytes(rx))
            if parsed:
                svc_hi, _, pb = parsed
                rx_magic = eh.read_varint_field(pb, 2, -1)
                matched = svc_hi == rqp.SID_QUICKLIST and rx_magic == ql_data_magic
                on_event(f'quicklist rx SID=0x{svc_hi:02x} magic={rx_magic}: {pb.hex()}',
                         level='ok' if matched else 'info')
                responses.append({'sid': hex(svc_hi), 'magic': rx_magic, 'pb': pb.hex()})
                if matched:
                    on_event('quicklist ACK received — device stored tasks', level='ok')
                    break
        except asyncio.TimeoutError:
            break
    acked = any(r.get('magic') == ql_data_magic for r in responses)
    if not acked:
        on_event('quicklist SID=0x0c: no matching ack in 3s', level='warn')

    # Step 3: Enable quicklist widget slot in native dashboard via CMD_DASHBOARD_RECEIVE +
    # display_setting=[WIDGET_QUICKLIST]. Same mechanism as display_enable for news — the
    # native dashboard only shows a widget that has been explicitly listed in display_setting.
    on_event('quicklist: sending display_setting=[WIDGET_QUICKLIST] to native dashboard (SID=0x01)...', level='info')
    magic_ql = session.next_magic()
    payload_ql = rdp.build_quicklist_display_enable(magic_ql)
    raw_ql = await session._send_and_get_payload(rdp.SID_DASHBOARD, eh.FLAG_REQUEST, magic_ql,
                                                 payload_ql, session.next_seq(),
                                                 'quicklist display_setting', timeout_s=4.0)
    ql_ack = decode_dashboard_ack(raw_ql)
    ql_flag = None
    if raw_ql is not None:
        ep = eh.read_bytes_field(raw_ql, 3)
        if ep is not None:
            ql_flag = eh.read_varint_field(ep, 2, 0)
    on_event(f'quicklist display_setting: {ql_ack}', level='ok' if ql_flag == 0 else 'warn')

    # Step 4: Stop heartbeat — native dashboard takes over in ~5s showing quicklist widget
    if stop_hub_heartbeat(session):
        on_event('quicklist: heartbeat stopped — native dashboard shows in ~5s', level='ok')

    if save:
        state.save_hub_state('quicklist', {'items': titles, 'tasks': [
            {'uid': t['uid'], 'title': t['title'], 'completed': t['completed']} for t in tasks]})
    return 200, {
        'items_sent': len(titles),
        'acked': acked,
        'dashboard_init_flag': init_flag,
        'ql_responses': responses,
        'display_enable': f'{ql_ack} flag={ql_flag}',
    }


async def api_push_quicklist(request):
    """Legacy direct push (scripts, tests): push now, save on success. The web UI uses /api/tasks."""
    if state.current_session() is None:
        return web.json_response({'error': 'not connected'}, status=503)
    data = await request.json()
    async with sync.ENGINE.exclusive():
        status, body = await push_quicklist(data.get('items', []))
    return web.json_response(body, status=status)


def on_quicklist_frame(cmd_id, pb):
    """Mirror the official app (blutter: ProtoQuicklistExt.onListenOsPushEvent / OsOperation):
    ITEM(f3) and MULT_ITEMS(f4) from the glasses are completion-status updates only; EVENT(f5)
    is a paging request answered with a MULT_ITEMS ADD page. Glasses can't add/delete tasks."""
    magic = eh.read_varint_field(pb, 2, -1)
    if magic in _ql_sent_magics:
        on_event(f'Quicklist ack magic={magic} pb={pb.hex()}', level='info')
        return
    on_event(f'Quicklist ← from glasses cmdId={cmd_id} magic={magic} pb={pb.hex()}', level='ok')

    event = rqp.decode_event(pb)
    if event is not None:
        session = state.context.get('session')
        if session is not None:
            state.SUP.spawn(answer_paging(session, *event), name='quicklist-paging', scope='connection')
        return

    updates = rqp.decode_status_updates(pb)

    tasks = load_tasks()
    by_uid = {t['uid']: t for t in tasks}
    changed = [u for u in updates if u['uid'] in by_uid and by_uid[u['uid']]['completed'] != u['completed']]
    for u in changed:
        by_uid[u['uid']]['completed'] = u['completed']
        on_event(f'Quicklist: "{by_uid[u["uid"]]["title"]}" marked '
                 f'{"done" if u["completed"] else "not done"} on glasses', level='ok')
    if changed:
        # Ticked on the glasses: they already show it, so this is saved without a push.
        state.save_hub_state('quicklist', {'items': [t['title'] for t in tasks], 'tasks': tasks, 'source': 'glasses'})
        notify_state_changed('quicklist')


async def answer_paging(session, event, pivot_uid):
    """UPDATE_DATA_UP → up to 20 tasks before the pivot uid; DOWN → up to 20 after it."""
    tasks = load_tasks()
    page = rqp.page_around(tasks, event, pivot_uid)
    items = [(t['uid'], tasks.index(t), t['completed'], 0, t['title'], rqp.TS_TYPE_TIME) for t in page]
    magic = session.next_magic()
    _ql_sent_magics.append(magic)
    frames = eh.frame_pb(rqp.build_quicklist_add_page(items, magic), rqp.SID_QUICKLIST,
                         eh.FLAG_REQUEST, session.next_seq())
    on_event(f'Quicklist paging {"up" if event == 1 else "down"} from uid={pivot_uid}: sending {len(items)} task(s)',
             level='info')
    await session._send_right(frames)


ROUTES = [
    ('POST', '/api/push_quicklist', api_push_quicklist),
    ('GET', '/api/tasks', api_tasks),
    ('POST', '/api/tasks', api_tasks),
]
