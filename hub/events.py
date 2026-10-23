"""The hub's event stream: the Live log tab, the WebSocket fan-out and the log file.

on_event() is the one call every part of the hub uses to report something. It appends to the
in-memory history (replayed to each new WebSocket client), sends it to every open page, and
writes it to the 'g2hub.event' logger (→ hub.jsonl). Other message types (connection, state,
glasses_status, ai) go to the pages only, via broadcast().
"""
import asyncio
import json
import logging
import time
from collections import deque

from hub.logs import UI_LEVELS

HISTORY_SIZE = 300
LINK_HISTORY_SIZE = 100

clients = set()                      # open WebSocketResponse objects
history = deque(maxlen=HISTORY_SIZE)  # replayed to each new client
link_history = deque(maxlen=LINK_HISTORY_SIZE)   # connection state changes (Report a problem)
_sends = set()                       # strong refs to in-flight send tasks (the loop keeps weak ones)
log = logging.getLogger('g2hub.event')


def to_json(event):
    return json.dumps(event)


async def _send(ws, payload):
    try:
        await ws.send_str(payload)
    except Exception:
        clients.discard(ws)


def broadcast(payload):
    """Send a JSON string to every open page. No-op outside a running event loop."""
    if not clients:
        return
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return
    for ws in list(clients):
        task = loop.create_task(_send(ws, payload))
        _sends.add(task)
        task.add_done_callback(_sends.discard)


def on_event(message, level='info', **extra):
    event = {'type': 'log', 'level': level, 'message': message, 'ts': time.time(), **extra}
    history.append(event)
    broadcast(to_json(event))
    log.log(UI_LEVELS.get(level, logging.INFO), '%s', message,
            extra={'ui_level': level, **({'data': extra} if extra else {})})


def note_link(state, detail=''):
    """Remember one connection state change (connecting, connected, connect failed,
    disconnected, paused, resumed) with its time, for the problem report."""
    link_history.append({'ts': time.time(), 'state': str(state), **({'detail': str(detail)[:200]} if detail else {})})


def on_connection_change(connected, context):
    context['connected'] = connected
    event = {'type': 'connection', 'connected': connected, 'ts': time.time()}
    history.append(event)
    broadcast(to_json(event))
    log.info('glasses %s', 'connected' if connected else 'disconnected')


def notify_state_changed(key):
    """Tell open browser tabs to reload /api/hub_state (not stored in log history)."""
    broadcast(to_json({'type': 'state', 'key': key}))
