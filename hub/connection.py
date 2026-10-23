"""The glasses link: connect, post-connect sequence, keep-alive watchdog, profile restore (the sync
engine, hub/sync.py), teardown, and pause/resume for system suspend and Bluetooth adapter power
(hub/power.py).

Everything tied to one connection runs in the supervisor's 'connection' scope and is cancelled
when the link drops, the user switches glasses, the machine suspends or the hub shuts down.
"""
import asyncio
import time

from g2 import app_sync
from g2 import dashboard as rdp
from g2 import device
from g2 import evenhub as eh
from g2 import file_service as fsp
from g2.session import GlassesSession, discover_pairs
from hub import frame_log, state, sync
from hub.events import note_link, on_connection_change, on_event
from hub.frames import on_device_frame
from hub.glasses import send_framed
from hub.routes import even_ai

RECONNECT_DELAY_S = state.RECONNECT_DELAY_S
TEARDOWN_TIMEOUT_S = 4.0

# Called with (connected: bool) after every connect / disconnect (hub.power uses it for the
# "keep connected when the lid closes" lock).
listeners = []
IDLE = asyncio.Event()       # set while no session is live (suspend waits for it)
IDLE.set()


def _notify_listeners(connected):
    for fn in list(listeners):
        try:
            fn(connected)
        except Exception as e:
            on_event(f'connection listener error: {e}', level='warn')


def paused():
    """Reasons the loop must not connect right now ('sleep', 'adapter')."""
    return state.context.setdefault('paused', set())


async def run_connect_sequence(session):
    steps = device.connect_sequence(session.next_magic)
    # Notifications are dropped unless notifEnable is set, and the glasses forget it on reboot
    # (firmware analysis) — so enable them (and bypass the app whitelist) on
    # every connect, not only when someone presses "Enable notifications".
    steps += [(fsp.SID_NOTIFICATION, fsp.build_notification_ctrl(session.next_magic()), 'right'),
              (fsp.SID_NOTIFICATION, fsp.build_whitelist_disable(session.next_magic()), 'right')]
    for sid, payload, lens in steps:
        await send_framed(session, sid, payload, lens)
        await asyncio.sleep(0.15)
    on_event(f'Connect sequence sent ({len(steps)} steps: role, time sync, settings read, units, '
             'onboarding finish, wear check, case, gestures)', level='ok')


async def maintenance_loop(session):
    """Every 60 s: keep-alive to both lenses (left first, like the app). Hourly: time re-sync.
    Watchdog: if the right lens misses two keep-alive echoes in a row, force a reconnect."""
    last_time_sync = time.time()
    state.context['keepalive_echo'] = time.time()
    missed = 0
    try:
        while True:
            await asyncio.sleep(device.KEEPALIVE_INTERVAL_S)
            sent_at = time.time()
            for i, (sid, payload, lens) in enumerate(device.keepalive_steps(session.next_magic)):
                await send_framed(session, sid, payload, lens)
                if i == 0:
                    await asyncio.sleep(device.KEEPALIVE_LEFT_LEAD_S)
            await asyncio.sleep(5)
            if state.context.get('keepalive_echo', 0) >= sent_at:
                missed = 0
            else:
                missed += 1
                on_event(f'Keep-alive: no echo from the right lens ({missed}/2)', level='warn')
                if missed >= 2:
                    on_event('Keep-alive: link looks dead — reconnecting', level='err')
                    state.request_reconnect('keep-alive watchdog')
                    return
            if time.time() - last_time_sync > 3600:
                await send_framed(session, device.SID, device.build_time_sync(session.next_magic()))
                last_time_sync = time.time()
    except asyncio.CancelledError:
        raise
    except Exception as e:
        on_event(f'Maintenance loop stopped: {e}', level='warn')


async def apply_profile(session):
    """Re-send the active glasses' saved configuration after (re)connecting, the way the official
    app restores widgets: the sync engine is attached to this session and pushes every section in
    the hub's order (settings, layout, weather, menu, tasks, calendar, news, stocks, health)
    RESTORE_DELAY_S after the link is up, plus anything edited while the glasses were away. A
    disconnect stops it; what did not go out is pushed on the next connect."""
    sync.ENGINE.attach(session, restore_all=True, delay=sync.RESTORE_DELAY_S)
    on_event(f'Profile restore queued: {", ".join(sync.RESTORE_ORDER)}', level='info')


async def bluetoothctl_disconnect(mac, timeout=5.0):
    """`bluetoothctl disconnect <mac>` without blocking the event loop (bounded to `timeout`)."""
    try:
        proc = await asyncio.create_subprocess_exec('bluetoothctl', 'disconnect', mac,
                                                    stdout=asyncio.subprocess.DEVNULL,
                                                    stderr=asyncio.subprocess.DEVNULL)
    except OSError as e:
        on_event(f'bluetoothctl unavailable: {e}', level='warn')
        return None
    try:
        return await asyncio.wait_for(proc.wait(), timeout)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        return None


async def _post_connect_prelude(session):
    """Dashboard prelude + dashboard init + SID 0x0d subscription (non-fatal)."""
    # Send the dashboard prelude (commandId=2, magic=156 on SID=0x01).
    # The real app sends this immediately after auth. It is a CMD_DASHBOARD_RECEIVE with
    # empty/zeroed nested fields — likely an "I am present" registration that activates the
    # firmware's news/widget push path. Calendar works without it, but AppSendNewsData may
    # require it. Fire-and-forget, drain any response bytes.
    await session._send_right([eh.PRELUDE_F5872])
    await asyncio.sleep(1.5)
    # drain any response notifications (same as the real app's _drain call)
    while True:
        try:
            await asyncio.wait_for(session.notes.get(), timeout=0.05)
        except asyncio.TimeoutError:
            break
    on_event('Prelude sent (dashboard init, commandId=2, magic=156)', level='info')
    # Full dashboard init (btsnoop 2026-09-28: display_mode=4 activates native dashboard
    # for all widget types at once — we were never sending this, which is why widgets showed
    # "add sources" instead of content).
    magic_init = session.next_magic()
    payload_init = rdp.build_dashboard_init(magic_init)
    raw_init = await session._send_and_get_payload(
        rdp.SID_DASHBOARD, eh.FLAG_REQUEST, magic_init, payload_init,
        session.next_seq(), 'connection dashboard init', timeout_s=4.0
    )
    init_flag = None
    if raw_init is not None:
        ep = eh.read_bytes_field(raw_init, 3)
        if ep is not None:
            init_flag = eh.read_varint_field(ep, 2, 0)  # field 1 is packageId, field 2 the result flag
    on_event(f'Dashboard init (display_mode=4): flag={init_flag}', level='ok' if init_flag == 0 else 'warn')
    # Subscribe to SID=0x0d (content-state notifications — btsnoop 2026-09-28: device fires
    # {f1=1,f3:{f1=1}} when content is ready and {f1=1,f3:empty} when consumed/displayed).
    # Subscription payload: {f1=0, magic=X} — one-time subscribe, device keeps notifying.
    magic_0d = session.next_magic()
    sub_payload = app_sync.build_subscribe(magic_0d)
    sub_frames = eh.frame_pb(sub_payload, app_sync.SID, eh.FLAG_REQUEST, session.next_seq())
    await session._send_right(sub_frames)
    on_event('SID=0x0d subscribed (content-state notifications)', level='info')


def _should_drop(session):
    return (not (session.right_client and session.left_client and session.right_client.is_connected
                 and session.left_client.is_connected)
            or state.context.get('reconnect_requested') or bool(paused()))


async def _wait_wake(timeout):
    """Sleep up to `timeout` s, returning early when state.WAKE is set (then clear it)."""
    try:
        await asyncio.wait_for(state.WAKE.wait(), timeout)
    except asyncio.TimeoutError:
        pass
    state.WAKE.clear()


async def _reconnect_delay():
    """The pause between attempts; skipped after a resume / adapter power-on (fast reconnect)."""
    if state.context.pop('fast_reconnect', False):
        return
    loop = asyncio.get_running_loop()
    end = loop.time() + RECONNECT_DELAY_S
    while loop.time() < end and not state.context.get('fast_reconnect'):
        await _wait_wake(end - loop.time())
    state.context.pop('fast_reconnect', None)


async def teardown(session, reason):
    """Drop everything tied to `session`: connection-scoped tasks, Even AI heartbeat, native app,
    and the BLE links (bounded, so a dead link cannot hang it)."""
    state.context['session'] = None
    sync.ENGINE.detach()                     # unsent sections stay queued for the next connect
    note_link('disconnected', reason)
    if state.context.get('connected'):
        on_connection_change(False, state.context)
    session.on_raw_frame = None
    session.on_disconnect = None
    even_ai.ai_stop_heartbeat()
    if state.APPS_CTL.current:
        state.APPS_CTL._ended(state.APPS_CTL.current)
    n = await state.SUP.cancel_scope('connection', timeout=TEARDOWN_TIMEOUT_S)
    if n:
        on_event(f'Stopped {n} connection task(s) ({reason})', level='info')
    try:
        await asyncio.wait_for(asyncio.shield(session.close()), TEARDOWN_TIMEOUT_S)
    except asyncio.CancelledError:
        raise
    except Exception as e:
        on_event(f'Session close: {e!r}', level='warn')
    IDLE.set()
    _notify_listeners(False)


async def _wait_while_paused():
    announced = False
    while paused():
        if not announced:
            on_event(f'Connection paused ({", ".join(sorted(paused()))}) — waiting', level='info')
            announced = True
        await _wait_wake(30)


async def adopt_discovered_pair(dev):
    """The active device has no lens addresses (fresh database, no G2_RIGHT_MAC / G2_LEFT_MAC):
    scan once and, if a complete pair is found, store it. A placeholder device that has no
    addresses at all takes over the discovered pair (keeping its settings); otherwise the pair is
    added and made the default. Returns the (possibly updated) device row."""
    on_event('No lens addresses configured — scanning for an Even G2 pair (8 s)...', level='info')
    try:
        found = await discover_pairs(timeout=8.0)
    except Exception as e:
        on_event(f'Scan failed: {e}', level='warn')
        return dev
    pair = next((p for p in found if p.get('complete')), None)
    if pair is None:
        return dev
    store = state.STORE
    other = next((d for d in store.devices() if d['pair_id'] == pair['pair_id']), None)
    if other is None and not (dev.get('right_mac') or dev.get('left_mac')):
        store.claim_pair(dev['id'], pair['pair_id'], pair['right_mac'], pair['left_mac'])
        dev_id = dev['id']
    else:
        dev_id = store.upsert_device(pair['pair_id'], pair['right_mac'], pair['left_mac'])
    store.set_default(dev_id)
    state.context['device_id'] = dev_id
    on_event(f'Found glasses {pair["pair_id"]}: R {pair["right_mac"]} / L {pair["left_mac"]}', level='ok')
    return store.device(dev_id)


async def connection_loop():
    context = state.context
    while True:
        await _wait_while_paused()
        dev = state.STORE.device(state.active_device_id()) or state.init_devices()
        context['reconnect_requested'] = False
        context.pop('reconnect_reason', None)
        if not (dev.get('right_mac') and dev.get('left_mac')):
            dev = await adopt_discovered_pair(dev)
        if not (dev.get('right_mac') and dev.get('left_mac')):
            on_event(f'Glasses "{dev["name"]}" have no lens addresses yet — use Scan in the Glasses card', level='warn')
            await _reconnect_delay()
            continue
        on_event(f'Scanning for {dev["name"]} ({dev["right_mac"]} / {dev["left_mac"]})...', level='info')
        context.pop('fast_reconnect', None)
        session = GlassesSession(initial_text='', right_mac=dev['right_mac'], left_mac=dev['left_mac'])
        frame_log.tap_session(session)       # recent frames for Report a problem (hub/report.py)
        note_link('connecting')
        IDLE.clear()
        try:
            connect_task = asyncio.ensure_future(session.connect(launch_app=True, skip_page=True))
            while not connect_task.done():
                await asyncio.wait({connect_task}, timeout=1.0)
                if paused() and not connect_task.done():
                    connect_task.cancel()
            await connect_task
        except asyncio.CancelledError:
            if connect_task.cancelled() and not asyncio.current_task().cancelling():
                on_event('Connect aborted (paused)', level='info')
                await teardown(session, 'connect aborted')
                continue
            await teardown(session, 'shutdown')
            raise
        except Exception as e:
            on_event(f'Connect failed: {e}', level='err')
            note_link('connect failed', type(e).__name__)
            context['session'] = None
            if context.get('connected'):
                on_connection_change(False, context)
            try:
                await asyncio.wait_for(asyncio.shield(session.close()), TEARDOWN_TIMEOUT_S)
            except (Exception, asyncio.TimeoutError):
                pass
            for mac in [dev['right_mac'], dev['left_mac']]:
                await bluetoothctl_disconnect(mac)
            IDLE.set()
            await _reconnect_delay()
            continue

        try:
            try:
                await _post_connect_prelude(session)
            except asyncio.CancelledError:
                raise
            except Exception as e:
                on_event(f'Prelude failed (non-fatal): {e}', level='warn')

            context['session'] = session
            on_connection_change(True, context)
            note_link('connected')
            on_event('Connected -- native dashboard is untouched and stays live.', level='ok')
            _notify_listeners(True)

            session.on_raw_frame = on_device_frame
            session.on_disconnect = lambda side: state.WAKE.set()
            state.STORE.mark_seen(dev['id'])
            context['glasses_status'] = {}

            # The official app's post-auth housekeeping (role, time sync, settings read, units,
            # onboarding FINISH, wear check, case battery, gestures) — captured byte-for-byte.
            try:
                await run_connect_sequence(session)
            except asyncio.CancelledError:
                raise
            except Exception as e:
                on_event(f'Connect sequence error (non-fatal): {e}', level='warn')
            state.SUP.spawn(maintenance_loop(session), name='maintenance', scope='connection')

            # Re-apply this pair's saved profile (settings, menu, tasks, calendar, news, ...) like the
            # official app: the sync engine pushes every section in order.
            state.SUP.spawn(apply_profile(session), name='apply-profile', scope='connection')

            # Wait for the link to drop (bleak disconnect callback wakes us; 1 s poll as a
            # fallback), a glasses switch / watchdog reconnect, or a pause (suspend, adapter off).
            while not _should_drop(session):
                await _wait_wake(1.0)
        except asyncio.CancelledError:
            await teardown(session, 'shutdown')
            raise

        reason = ('paused: ' + ', '.join(sorted(paused()))) if paused() else context.get('reconnect_reason') or (
            'switch' if context.get('reconnect_requested') else 'link lost')
        if paused():
            on_event(f'Disconnecting cleanly ({reason})...', level='info')
        else:
            on_event('Switching glasses...' if context.get('reconnect_requested') else 'Disconnected -- reconnecting...',
                     level='info' if context.get('reconnect_requested') else 'err')
        await teardown(session, reason)
        if not paused():
            await _reconnect_delay()


# ── hooks for hub.power ─────────────────────────────────────────────────────────────────────
async def pause(reason, timeout=TEARDOWN_TIMEOUT_S + 1.0):
    """Stop using the radio (suspend / adapter off): tear the session down and wait (bounded)
    until it is gone. Returns True if the link is down within `timeout`."""
    paused().add(reason)
    note_link('paused', reason)
    state.WAKE.set()
    try:
        await asyncio.wait_for(IDLE.wait(), timeout)
        return True
    except asyncio.TimeoutError:
        return False


def resume(reason, fast=True):
    """Allow connecting again; with fast=True skip the reconnect delay."""
    paused().discard(reason)
    note_link('resumed', reason)
    if fast:
        state.context['fast_reconnect'] = True
    state.WAKE.set()
