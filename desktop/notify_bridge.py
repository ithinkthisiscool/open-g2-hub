"""Desktop notifications -> G2 glasses bridge (optional, OFF by default).

Watches the session D-Bus for org.freedesktop.Notifications.Notify calls (the standard way every
Linux app posts a desktop notification) and forwards the ones from allow-listed apps to the hub's
POST /api/notify_send, which shows them on the glasses.

Privacy: the monitor can *see* every desktop notification, but only allow-listed apps are
forwarded, only to the local hub (127.0.0.1), and nothing is written to disk. Log lines contain
the app name and the decision, never the notification text.

Backends: dbus-fast (preferred, in-process) or the `dbus-monitor` CLI as a fallback.

Standalone test (prints decisions, sends nothing):
    .venv/bin/python desktop/notify_bridge.py --dry-run --allow '*'
    notify-send -a Firefox "Hello" "World"
"""
import argparse
import asyncio
import collections
import html
import queue
import re
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from config import APP_NAME, Config  # noqa: E402
from hubclient import HubClient, HubError  # noqa: E402

MATCH_RULE = "type='method_call',interface='org.freedesktop.Notifications',member='Notify'"
# Never forward our own notifications (loop) or obvious system noise.
ALWAYS_IGNORE = {APP_NAME.lower(), 'g2hub', 'notify-send-g2hub'}
_TAG_RE = re.compile(r'<[^>]+>')


def clean_text(s, limit):
    """Notification bodies may contain a small HTML subset; the glasses want plain text."""
    s = html.unescape(_TAG_RE.sub('', s or ''))
    s = ' '.join(s.split())
    return s[:limit]


class NotificationFilter:
    """Pure decision logic (allow-list, rate limit, de-duplication). Thread-safe."""

    def __init__(self, cfg):
        self.cfg = cfg
        self._sent = collections.deque()        # timestamps of forwarded notifications
        self._recent = {}                       # (app, title, body) -> last seen time
        self._lock = threading.Lock()

    def allowed_app(self, app):
        a = (app or '').strip().lower()
        if not a or a in ALWAYS_IGNORE:
            return False
        allow = [str(x).strip().lower() for x in (self.cfg['allow_apps'] or [])]
        return '*' in allow or a in allow

    def decide(self, app, summary, body, now=None):
        """Return (forward: bool, title, message, reason)."""
        now = time.monotonic() if now is None else now
        if not self.allowed_app(app):
            return False, None, None, 'app not in allow-list'
        title = clean_text(summary, 64) or app
        message = clean_text(body, 512)
        mode = self.cfg['forward_content']
        if mode == 'title':
            message = ''
        elif mode == 'app':
            title, message = app[:64], 'New notification'
        with self._lock:
            key = (app.lower(), title, message)
            win = float(self.cfg['dedupe_window_s'])
            self._recent = {k: t for k, t in self._recent.items() if now - t < win}
            if key in self._recent:
                return False, None, None, 'duplicate'
            while self._sent and now - self._sent[0] > 60:
                self._sent.popleft()
            if self._sent and now - self._sent[-1] < float(self.cfg['min_interval_s']):
                return False, None, None, 'rate limited (min interval)'
            if len(self._sent) >= int(self.cfg['max_per_minute']):
                return False, None, None, 'rate limited (per minute)'
            self._recent[key] = now
            self._sent.append(now)
        return True, title, message, 'ok'


# --- D-Bus monitor backends: each calls on_notify(app, summary, body) from a background thread ---

class DbusFastMonitor:
    name = 'dbus-fast'

    def __init__(self, on_notify):
        self.on_notify = on_notify
        self._loop = None
        self._thread = None
        self._bus = None
        self._owner_bus = None
        self._server_owner = None

    @staticmethod
    def available():
        try:
            import dbus_fast.aio  # noqa: F401
            return True
        except ImportError:
            return False

    def start(self):
        ready = threading.Event()
        err = []

        def run():
            self._loop = asyncio.new_event_loop()
            try:
                self._loop.run_until_complete(self._connect())
            except Exception as e:  # noqa: BLE001
                err.append(e)
                ready.set()
                return
            ready.set()
            self._loop.run_forever()

        self._thread = threading.Thread(target=run, name='notify-monitor', daemon=True)
        self._thread.start()
        ready.wait(10)
        if err:
            raise RuntimeError(f'dbus-fast monitor failed: {err[0]}')

    async def _connect(self):
        from dbus_fast import BusType, Message, MessageType
        from dbus_fast.aio import MessageBus
        bus = await MessageBus(bus_type=BusType.SESSION).connect()
        reply = await bus.call(Message(
            destination='org.freedesktop.DBus', path='/org/freedesktop/DBus',
            interface='org.freedesktop.DBus.Monitoring', member='BecomeMonitor',
            signature='asu', body=[[MATCH_RULE], 0]))
        if reply.message_type == MessageType.ERROR:
            raise RuntimeError(reply.body[0] if reply.body else reply.error_name)
        await self._track_server_owner()

        def handler(msg):
            # A monitor connection must never send anything (the bus would drop it), so always
            # return True: that stops dbus-fast from auto-replying "unknown method".
            try:
                if msg.member == 'Notify' and msg.message_type == MessageType.METHOD_CALL \
                        and len(msg.body) >= 5 and msg.sender != self._server_owner:
                    self.on_notify(str(msg.body[0]), str(msg.body[3]), str(msg.body[4]))
            except Exception as e:  # noqa: BLE001
                print(f'[notify] handler error: {e}', flush=True)
            return True

        bus.add_message_handler(handler)
        self._bus = bus

    async def _track_server_owner(self):
        """Some notification daemons (GNOME's) re-send each Notify to the shell. Calls *from* the
        notification server itself are those relays, not new notifications, so remember who owns
        org.freedesktop.Notifications (via a second, ordinary connection) and ignore them."""
        from dbus_fast import BusType, Message, MessageType
        from dbus_fast.aio import MessageBus
        self._server_owner = None
        bus = await MessageBus(bus_type=BusType.SESSION).connect()
        reply = await bus.call(Message(destination='org.freedesktop.DBus', path='/org/freedesktop/DBus',
                                       interface='org.freedesktop.DBus', member='GetNameOwner',
                                       signature='s', body=['org.freedesktop.Notifications']))
        if reply.message_type == MessageType.METHOD_RETURN:
            self._server_owner = reply.body[0]
        await bus.call(Message(destination='org.freedesktop.DBus', path='/org/freedesktop/DBus',
                               interface='org.freedesktop.DBus', member='AddMatch', signature='s',
                               body=["type='signal',interface='org.freedesktop.DBus',member='NameOwnerChanged',"
                                     "arg0='org.freedesktop.Notifications'"]))

        def owner_changed(msg):
            if msg.member == 'NameOwnerChanged' and msg.body and msg.body[0] == 'org.freedesktop.Notifications':
                self._server_owner = msg.body[2] or None
            return None

        bus.add_message_handler(owner_changed)
        self._owner_bus = bus

    def stop(self):
        if self._loop and self._bus:
            self._loop.call_soon_threadsafe(self._bus.disconnect)
            if self._owner_bus:
                self._loop.call_soon_threadsafe(self._owner_bus.disconnect)
            self._loop.call_soon_threadsafe(self._loop.stop)


class DbusMonitorCli:
    """Fallback: parse `dbus-monitor --session` text output."""
    name = 'dbus-monitor'

    def __init__(self, on_notify):
        self.on_notify = on_notify
        self.proc = None
        self._owner, self._owner_t = None, 0.0

    def _server_owner(self):
        if time.monotonic() - self._owner_t > 30:
            self._owner_t = time.monotonic()
            try:
                out = subprocess.run(['dbus-send', '--session', '--print-reply', '--dest=org.freedesktop.DBus',
                                      '/org/freedesktop/DBus', 'org.freedesktop.DBus.GetNameOwner',
                                      'string:org.freedesktop.Notifications'],
                                     capture_output=True, text=True, timeout=3).stdout
                m = re.search(r'string "([^"]+)"', out)
                self._owner = m.group(1) if m else None
            except (OSError, subprocess.SubprocessError):
                self._owner = None
        return self._owner

    @staticmethod
    def available():
        return shutil.which('dbus-monitor') is not None

    def start(self):
        self.proc = subprocess.Popen(['dbus-monitor', '--session', MATCH_RULE], stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, text=True, bufsize=1)
        threading.Thread(target=self._read, name='notify-monitor', daemon=True).start()

    def _read(self):
        args, in_call = [], False
        str_re = re.compile(r'^   string "(.*)"$')
        pending_multiline = None
        for line in self.proc.stdout:
            line = line.rstrip('\n')
            if line.startswith('method call') or line.startswith('signal') or line.startswith('method return'):
                self._flush(args, in_call)
                args, pending_multiline = [], None
                in_call = 'member=Notify' in line and line.startswith('method call')
                sm = re.search(r' sender=(\S+)', line)
                if in_call and sm and sm.group(1) == self._server_owner():
                    in_call = False          # relay from the notification daemon itself
                continue
            if not in_call or len(args) >= 5:
                continue
            if pending_multiline is not None:        # string spanning several lines
                if line.endswith('"'):
                    args.append(pending_multiline + '\n' + line[:-1])
                    pending_multiline = None
                else:
                    pending_multiline += '\n' + line
                continue
            m = str_re.match(line)
            if m:
                args.append(m.group(1))
            elif line.startswith('   string "'):
                pending_multiline = line[len('   string "'):]
            elif line.startswith('   uint32 '):
                args.append(line.split()[-1])
        self._flush(args, in_call)

    def _flush(self, args, in_call):
        if in_call and len(args) >= 5:
            try:
                self.on_notify(args[0], args[3], args[4])
            except Exception as e:  # noqa: BLE001
                print(f'[notify] handler error: {e}', flush=True)

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()


class NotificationBridge:
    """Monitor + filter + a single sender thread (so a slow hub never blocks D-Bus handling)."""

    def __init__(self, client, cfg, dry_run=False, log=print, backend=None):
        self.client = client
        self.cfg = cfg
        self.filter = NotificationFilter(cfg)
        self.dry_run = dry_run
        self.log = log
        self.monitor = None
        self._q = queue.Queue(maxsize=20)
        self._stop = threading.Event()
        self.forwarded = 0
        self.backend = backend

    @property
    def running(self):
        return self.monitor is not None

    def start(self):
        if self.monitor:
            return self.monitor.name
        errors = []
        for cls in (DbusFastMonitor, DbusMonitorCli):
            if (self.backend and cls.name != self.backend) or not cls.available():
                continue
            mon = cls(self._on_notify)
            try:
                mon.start()
            except Exception as e:  # noqa: BLE001
                errors.append(str(e))
                continue
            self.monitor = mon
            break
        if not self.monitor:
            raise RuntimeError('no D-Bus monitor backend available: ' + ('; '.join(errors) or
                               'install dbus-fast or dbus-monitor'))
        self._stop.clear()
        threading.Thread(target=self._sender, name='notify-sender', daemon=True).start()
        self.log(f'[notify] forwarding desktop notifications via {self.monitor.name} '
                 f'(allow-list: {self.cfg["allow_apps"] or "empty - nothing will be forwarded"})')
        return self.monitor.name

    def stop(self):
        if self.monitor:
            self.monitor.stop()
            self.monitor = None
            self._stop.set()
            self._q.put(None)
            self.log('[notify] forwarding stopped')

    def _on_notify(self, app, summary, body):
        ok, title, message, reason = self.filter.decide(app, summary, body)
        self.log(f'[notify] {app!r}: {"forward" if ok else "skip"} ({reason})')
        if ok:
            try:
                self._q.put_nowait((app, title, message))
            except queue.Full:
                self.log('[notify] queue full, dropping')

    def _sender(self):
        while not self._stop.is_set():
            item = self._q.get()
            if item is None:
                return
            app, title, message = item
            if self.dry_run:
                self.log(f'[notify] DRY RUN would send: title={title!r} message={message!r}')
                continue
            try:
                self.client.notify(title, message, display_name=app[:32])
                self.forwarded += 1
            except HubError as e:
                self.log(f'[notify] hub refused notification from {app!r}: {e}')


def main():
    ap = argparse.ArgumentParser(description='Forward desktop notifications to the G2 glasses.')
    ap.add_argument('--url', default='http://127.0.0.1:8766', help='hub base URL')
    ap.add_argument('--allow', action='append', help="app name to allow (repeatable, '*' = all); "
                    'overrides allow_apps from the config file')
    ap.add_argument('--dry-run', action='store_true', help='print what would be forwarded, send nothing')
    ap.add_argument('--backend', choices=['dbus-fast', 'dbus-monitor'], help='force a monitor backend')
    args = ap.parse_args()
    cfg = Config()
    if args.allow:
        cfg.data['allow_apps'] = args.allow          # in memory only, not saved
    bridge = NotificationBridge(HubClient(args.url), cfg, dry_run=args.dry_run,
                                log=lambda m: print(m, flush=True), backend=args.backend)
    bridge.start()
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        bridge.stop()


if __name__ == '__main__':
    main()
