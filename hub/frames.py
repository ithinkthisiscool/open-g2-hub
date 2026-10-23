"""Read-only tap on every frame from the glasses (session.on_raw_frame): dispatches events to the
feature modules and keeps the live glasses status (battery, worn, case, firmware, ...)."""
import time

from g2 import app_sync
from g2 import dashboard as rdp
from g2 import device
from g2 import even_ai as ai
from g2 import evenhub as eh
from g2 import quicklist as rqp
from g2 import settings as gset
from g2 import sids
from g2 import translate as tr
from hub import frame_log, state
from hub.events import broadcast, on_event, to_json
from g2 import health as ghealth
from hub.routes import even_ai, news, tasks, watchface

SID_NAMES = sids.NAMES
LOW_BATTERY_LEVELS = (20, 10)   # the firmware has no low-battery warning of its own
_news_upgrade_last = 0.0


def _check_low_battery(status):
    """Warn once per threshold (20 %, 10 %) on the glasses; re-arm when charging or above 25 %."""
    batt, charging = status.get('battery'), status.get('charging')
    warned = state.context.setdefault('battery_warned', set())
    if batt is None:
        return
    if charging or batt > 25:
        warned.clear()
        return
    for level in LOW_BATTERY_LEVELS:
        if batt <= level and level not in warned:
            warned.add(level)
            on_event(f'Glasses battery low: {batt}%', level='warn')
            state.SUP.spawn(state.post_self('/api/notify_send', {
                'title': 'Battery low', 'message': f'Glasses battery at {batt}%. Put them in the case to charge.',
                'display_name': 'G2 Hub'}), name='low-battery-notify', scope='connection')
            break


def update_glasses_status(values):
    """Merge live values reported by the glasses (battery, charging, firmware, worn, case…) into
    the status shown in the Glasses card, and remember them for this pair."""
    status = state.context.setdefault('glasses_status', {})
    changed = {k: v for k, v in values.items() if status.get(k) != v}
    if not changed:
        return
    status.update(changed)
    status['updated_at'] = int(time.time())
    _check_low_battery(status)
    dev = state.active_device_id()
    if dev is not None:
        state.STORE.set(dev, '_glasses_status', status)
        fw = status.get('right_version') or status.get('left_version')
        if fw and ('right_version' in changed or 'left_version' in changed):
            state.STORE.mark_seen(dev, firmware=fw)
    broadcast(to_json({'type': 'glasses_status', 'status': status}))


def on_device_frame(svc_hi, _svc_lo, pb):
    """Read-only tap on every incoming frame (session.on_raw_frame). Must not await or consume
    session.notes -- acks for in-flight pushes are routed by the session."""
    global _news_upgrade_last
    frame_log.record('rx', svc_hi, pb)
    cmd_id = eh.read_varint_field(pb, 1, -1)

    if svc_hi == 0x01 and cmd_id == rdp.CMD_DEV_REQUEST_NEWS_UPGRADE:
        now = time.time()
        if now - _news_upgrade_last > 30.0:
            _news_upgrade_last = now
            on_event('News widget: device requested refresh (cmdId=11) — fetching fresh feed', level='ok')
            news.refresh_in_background(force_fetch=True, scope='connection')
        else:
            on_event('News widget: refresh request (cmdId=11) within 30s cooldown — skipped', level='info')

    elif svc_hi == 0x01 and cmd_id == rdp.CMD_DEV_NOTIFY_NEWS_EVENT:
        # f14 {1 eventID: 0 expand-list, 1 back-to-widget, 2 scroll, 3 open-article, 4 back-to-list; 2 newsId}
        ev = eh.read_bytes_field(pb, 14)
        kind = eh.read_varint_field(ev, 1, 0) if ev is not None else None
        nid = eh.read_varint_field(ev, 2, 0) if ev is not None else None
        label = {0: 'expand list', 1: 'back to widget', 2: 'scroll', 3: 'open article', 4: 'back to list'}.get(kind, kind)
        on_event(f'News widget: {label} (newsId={nid})', level='info')

    elif svc_hi == 0x01 and cmd_id == 4:
        # Alternate refresh trigger: appReceive → widgetComponents → news → applyEvent{requiredCount, requiredStartId}
        on_event(f'Dashboard cmd=4 from glasses (possible news applyEvent) pb={pb.hex()}', level='info')

    elif svc_hi == ai.SID:
        even_ai.on_ai_frame(cmd_id, pb)

    elif svc_hi == app_sync.SID:
        # AppSync {1 cmd, 2 magic, 3 {1 backgroundAppID, 2 foregroundAppID}} -- ids are SIDs.
        info = app_sync.decode(pb)
        fg = info['foreground'] or 0
        state.context['foreground_app'] = fg
        on_event(f"App sync SID=0x0d: foreground={info['foreground_name'] or 'none'} "
                 f"background={info['background_name'] or 'none'}", level='info')

    elif svc_hi == rqp.SID_QUICKLIST:
        tasks.on_quicklist_frame(cmd_id, pb)

    elif svc_hi == watchface.wf.SID:
        watchface.on_frame(pb)

    elif svc_hi == ghealth.SID:
        d = ghealth.decode(pb)
        on_event(f'Health ← {d.get("name")} error={d.get("error", 0)} magic={d.get("magic")}', level='info')

    elif svc_hi in (0x05, 0x06, 0x08):
        state.APPS_CTL.on_frame(svc_hi, pb)
        if svc_hi == tr.SID:
            msg = tr.decode(pb)
            if msg['cmd'] == tr.CMD_NOTIFY and msg.get('value') == tr.TCMD_CLOSE:
                even_ai.on_translate_closed_on_glasses()

    elif svc_hi == device.SID:
        msg = device.decode(pb)
        if msg['cmd'] == device.CMD_KEEPALIVE:
            state.context['keepalive_echo'] = time.time()
        elif msg['cmd'] != device.CMD_AUTH:
            on_event(f'Device ← {msg["label"]}', level='info' if not msg['result'] else 'warn')

    elif svc_hi == gset.SID:
        msg = gset.decode(pb)
        if msg['values']:
            update_glasses_status(gset.with_defaults(msg['values']) if not msg['push'] else msg['values'])
        if not msg['push']:
            on_event(f'Settings ← {msg["label"]}', level='info')

    elif svc_hi == device.SID_ONBOARDING:
        msg = device.decode_onboarding(pb)
        if msg['worn'] is not None:
            update_glasses_status({'worn': msg['worn']})
        on_event(f'Onboarding ← {msg["label"]}', level='info')

    elif svc_hi == device.SID_CASE:
        case = device.decode_case(pb)
        if case:
            update_glasses_status({f'case_{k}': v for k, v in case.items() if k != 'magic' and v is not None})

    elif svc_hi == gset.SID_MODULE:
        msg = gset.decode_module(pb)
        if msg['timeout'] is not None:
            update_glasses_status({'display_timeout': 'never' if msg['timeout_never'] else msg['timeout']})
        on_event(f'Module config ← {msg["name"]} language={msg["language"]} timeout={msg["timeout"]}', level='info')

    elif svc_hi not in (0x01, eh.SID_EVENHUB):
        # Unmapped channels: log everything so on-glass actions can be reverse-engineered.
        on_event(f'Device frame SID=0x{svc_hi:02x} cmdId={cmd_id} pb={pb.hex()}', level='info')
