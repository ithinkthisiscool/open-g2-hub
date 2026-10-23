"""System power events for the glasses link: laptop suspend/resume (lid close) and Bluetooth
adapter power.

Why: when the lid closes the machine suspends, the BLE links die mid-write, and on resume the hub
used to find a dead session, wait for the watchdog and reconnect slowly. Now:

  * logind PrepareForSleep(true)  → stop the keep-alive and every connection task, disconnect
    both lenses cleanly, then release our *delay* inhibitor so the suspend proceeds.
  * logind PrepareForSleep(false) → take the delay lock again, wait for the adapter to be
    powered, and reconnect at once (no reconnect delay; g2's BlueZ fast path by address, with
    its scan fallback), then the usual connect sequence and profile restore.
  * org.bluez Adapter1 Powered false/true → pause / fast reconnect the same way.
  * Option "keep connected when the lid closes" (hub.json keep_connected_lid_closed): while this
    option is on, the hub holds a logind *block* inhibitor on handle-lid-switch:sleep the whole
    time it runs, so closing the lid does not suspend — the glasses link AND the web dashboard
    stay up regardless of whether the glasses are currently connected. Released on explicit sleep
    and when the option is turned off. Off by default.

Signals come from a pluggable source: dbus-fast on the system bus when importable, otherwise
`gdbus monitor` subprocesses. Tests inject a FakeSignalSource. Inhibitor locks are held by a
`systemd-inhibit ... sleep infinity` child process (killing it releases the lock).
"""
import asyncio
import importlib
import logging
import re
import shutil

from hub.events import on_event

log = logging.getLogger('g2hub.power')

LOGIN1 = 'org.freedesktop.login1'
LOGIN1_PATH = '/org/freedesktop/login1'
LOGIN1_MANAGER = 'org.freedesktop.login1.Manager'
BLUEZ = 'org.bluez'
ADAPTER_IFACE = 'org.bluez.Adapter1'
PROPS_IFACE = 'org.freedesktop.DBus.Properties'
DEFAULT_ADAPTER = '/org/bluez/hci0'

SLEEP = 'sleep'              # event kinds emitted by signal sources
ADAPTER = 'adapter_powered'


# ── signal sources ──────────────────────────────────────────────────────────────────────────
class DbusFastSource:
    """Listens on the system bus with dbus-fast (match rules + a message handler)."""

    name = 'dbus-fast'

    def __init__(self):
        importlib.import_module('dbus_fast.aio')     # ImportError → default_source() falls back
        self._bus = None

    async def run(self, emit):
        from dbus_fast import BusType, Message, MessageType
        from dbus_fast.aio import MessageBus
        bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
        self._bus = bus
        rules = [f"type='signal',interface='{LOGIN1_MANAGER}',member='PrepareForSleep',path='{LOGIN1_PATH}'",
                 f"type='signal',sender='{BLUEZ}',interface='{PROPS_IFACE}',member='PropertiesChanged',"
                 f"arg0='{ADAPTER_IFACE}'"]
        for rule in rules:
            await bus.call(Message(destination='org.freedesktop.DBus', path='/org/freedesktop/DBus',
                                   interface='org.freedesktop.DBus', member='AddMatch', signature='s', body=[rule]))

        def handler(msg):
            if msg.message_type != MessageType.SIGNAL:
                return
            if msg.member == 'PrepareForSleep' and msg.interface == LOGIN1_MANAGER:
                emit(SLEEP, bool(msg.body[0]), None)
            elif (msg.member == 'PropertiesChanged' and msg.body and msg.body[0] == ADAPTER_IFACE
                  and 'Powered' in msg.body[1]):
                emit(ADAPTER, bool(msg.body[1]['Powered'].value), msg.path)
        bus.add_message_handler(handler)
        try:
            await bus.wait_for_disconnect()
        finally:
            bus.disconnect()

    async def adapter_powered(self, path=DEFAULT_ADAPTER):
        from dbus_fast import Message
        if self._bus is None:
            return await _busctl_adapter_powered(path)
        reply = await self._bus.call(Message(destination=BLUEZ, path=path, interface=PROPS_IFACE, member='Get',
                                             signature='ss', body=[ADAPTER_IFACE, 'Powered']))
        return bool(reply.body[0].value) if reply.body else None


_SLEEP_RE = re.compile(r'PrepareForSleep \((true|false),?\)')
_POWERED_RE = re.compile(r"^(/org/bluez/\w+): .*PropertiesChanged \('org\.bluez\.Adapter1', \{[^}]*'Powered': <(true|false)>")


def parse_gdbus_line(line):
    """One `gdbus monitor` line → (kind, value, path) or None."""
    m = _SLEEP_RE.search(line)
    if m and LOGIN1_MANAGER in line:
        return SLEEP, m.group(1) == 'true', None
    m = _POWERED_RE.search(line)
    if m:
        return ADAPTER, m.group(2) == 'true', m.group(1)
    return None


class GdbusMonitorSource:
    """Fallback: two `gdbus monitor --system` children (logind, bluez), parsed line by line."""

    name = 'gdbus monitor'

    def __init__(self):
        if not shutil.which('gdbus'):
            raise RuntimeError('gdbus not found')

    async def _watch(self, args, emit):
        proc = await asyncio.create_subprocess_exec('gdbus', 'monitor', '--system', *args,
                                                    stdout=asyncio.subprocess.PIPE,
                                                    stderr=asyncio.subprocess.DEVNULL)
        try:
            async for raw in proc.stdout:
                ev = parse_gdbus_line(raw.decode(errors='replace'))
                if ev:
                    emit(*ev)
        finally:
            if proc.returncode is None:
                proc.kill()
                await proc.wait()

    async def run(self, emit):
        await asyncio.gather(self._watch(['--dest', LOGIN1, '--object-path', LOGIN1_PATH], emit),
                             self._watch(['--dest', BLUEZ], emit))

    async def adapter_powered(self, path=DEFAULT_ADAPTER):
        return await _busctl_adapter_powered(path)


async def _busctl_adapter_powered(path=DEFAULT_ADAPTER):
    try:
        proc = await asyncio.create_subprocess_exec('busctl', 'get-property', BLUEZ, path, ADAPTER_IFACE, 'Powered',
                                                    stdout=asyncio.subprocess.PIPE,
                                                    stderr=asyncio.subprocess.DEVNULL)
        out, _ = await asyncio.wait_for(proc.communicate(), 3.0)
    except (OSError, asyncio.TimeoutError):
        return None
    text = out.decode().strip()        # "b true"
    return None if not text else text.endswith('true')


def default_source():
    """dbus-fast if importable, else gdbus monitor, else None (power events disabled)."""
    for cls in (DbusFastSource, GdbusMonitorSource):
        try:
            return cls()
        except Exception as e:
            log.info('power source %s unavailable: %s', cls.__name__, e)
    return None


# ── inhibitor locks ─────────────────────────────────────────────────────────────────────────
class Inhibitor:
    """A logind inhibitor lock held by a `systemd-inhibit ... sleep infinity` child process."""

    def __init__(self, what, mode, why):
        self.what, self.mode, self.why = what, mode, why
        self._proc = None

    @property
    def held(self):
        return self._proc is not None and self._proc.returncode is None

    async def acquire(self):
        if self.held:
            return True
        try:
            self._proc = await asyncio.create_subprocess_exec(
                'systemd-inhibit', f'--what={self.what}', f'--mode={self.mode}', '--who=G2 Hub',
                f'--why={self.why}', 'sleep', 'infinity',
                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE)
        except OSError as e:
            log.warning('systemd-inhibit unavailable: %s', e)
            self._proc = None
            return False
        try:                                   # refused (polkit) → the child exits at once
            await asyncio.wait_for(self._proc.wait(), 0.5)
        except asyncio.TimeoutError:
            return True
        err = (await self._proc.stderr.read()).decode(errors='replace').strip()
        log.warning('inhibitor %s/%s refused: %s', self.what, self.mode, err)
        self._proc = None
        return False

    async def release(self):
        proc, self._proc = self._proc, None
        if proc is None or proc.returncode is not None:
            return
        proc.terminate()
        try:
            await asyncio.wait_for(proc.wait(), 2.0)
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()


# ── the manager ─────────────────────────────────────────────────────────────────────────────
class PowerManager:
    """Reacts to sleep / adapter events by pausing and resuming the connection loop.

    link.pause(reason) → awaitable, tears the session down (bounded) and blocks reconnects;
    link.resume(reason, fast=True) → allows reconnecting at once. `inhibitor_factory(what, mode,
    why)` makes lock objects with acquire()/release()/held (tests pass fakes)."""

    ADAPTER_WAIT_S = 15.0
    SLEEP_DISCONNECT_TIMEOUT_S = 4.0     # logind's default InhibitDelayMaxSec is 5 s

    def __init__(self, link, source=None, inhibitor_factory=Inhibitor, keep_connected=False, report=on_event):
        self.link = link
        self.source = source
        self.keep_connected = bool(keep_connected)
        self.report = report
        self.delay_lock = inhibitor_factory('sleep', 'delay', 'Disconnect the G2 glasses cleanly before sleep')
        self.block_lock = inhibitor_factory('handle-lid-switch:sleep', 'block',
                                            'Keep the G2 glasses connected while the lid is closed')
        self.connected = False
        self.suspended = False
        self._queue = asyncio.Queue()
        self.handled = []                # (kind, value) of every processed event (for tests/status)
        self._bg = set()

    def _background(self, coro):
        task = asyncio.ensure_future(coro)
        self._bg.add(task)
        task.add_done_callback(self._bg.discard)
        return task

    def _say(self, msg, level='info'):
        log.info(msg)
        self.report(msg, level=level)

    # events arrive from the source's callback; they are handled one at a time, in order
    def emit(self, kind, value, path=None):
        self._queue.put_nowait((kind, value, path))

    async def run(self):
        """Take the delay lock, start the signal source, and process events until cancelled."""
        if self.source is None:
            self._say('Power events: no D-Bus access (dbus-fast/gdbus missing) — suspend handling off', 'warn')
            return
        await self.delay_lock.acquire()
        self._say(f'Power events: watching logind sleep + BlueZ adapter power via {self.source.name}'
                  f'{" (delay lock held)" if self.delay_lock.held else " (no delay lock)"}')
        await self._sync_block_lock()   # take the lid-close lock now if the option is on (not only on connect)
        src = asyncio.ensure_future(self.source.run(self.emit))
        try:
            while True:
                getter = asyncio.ensure_future(self._queue.get())
                done, _ = await asyncio.wait({getter, src}, return_when=asyncio.FIRST_COMPLETED)
                if getter not in done:
                    getter.cancel()
                    exc = src.exception() if not src.cancelled() else None
                    self._say(f'Power events: signal source stopped ({exc!r})', 'warn')
                    return
                kind, value, path = getter.result()
                try:
                    await self.handle(kind, value, path)
                except asyncio.CancelledError:
                    raise
                except Exception as e:
                    log.exception('power event %s=%s failed', kind, value)
                    self._say(f'Power event {kind}={value} failed: {e}', 'err')
        finally:
            src.cancel()
            await asyncio.gather(src, return_exceptions=True)
            await self.block_lock.release()
            await self.delay_lock.release()

    async def handle(self, kind, value, path=None):
        self.handled.append((kind, value))
        if kind == SLEEP and value:
            await self.before_sleep()
        elif kind == SLEEP:
            await self.after_resume()
        elif kind == ADAPTER and not value:
            self._say(f'Bluetooth adapter {path or ""} powered off — pausing the glasses link', 'warn')
            await self.link.pause('adapter')
        elif kind == ADAPTER:
            self._say(f'Bluetooth adapter {path or ""} powered on — reconnecting now', 'ok')
            self.link.resume('adapter', fast=True)

    async def before_sleep(self):
        self.suspended = True
        self._say('System is going to sleep: stopping keep-alive and connection tasks, disconnecting the glasses')
        ok = await self.link.pause('sleep', timeout=self.SLEEP_DISCONNECT_TIMEOUT_S)
        self._say('Glasses disconnected cleanly before sleep' if ok else
                  'Glasses did not disconnect within the sleep delay; suspending anyway', 'ok' if ok else 'warn')
        await self.block_lock.release()
        await self.delay_lock.release()
        self._say('Delay lock released — system may sleep now')

    async def after_resume(self):
        self.suspended = False
        self._say('System resumed: re-arming the sleep delay lock')
        await self.delay_lock.acquire()
        await self._sync_block_lock()   # re-take the lid-close lock after resume if the option is on
        powered = await self._wait_adapter()
        self._say(f'Bluetooth adapter {"powered" if powered else "state unknown / still off"} — '
                  'fast reconnect (BlueZ fast path by address, scan fallback)', 'ok' if powered else 'warn')
        self.link.resume('sleep', fast=True)

    async def _wait_adapter(self):
        """Wait (bounded) until the adapter reports Powered=true after resume."""
        getter = getattr(self.source, 'adapter_powered', None)
        if getter is None:
            return None
        loop = asyncio.get_running_loop()
        end = loop.time() + self.ADAPTER_WAIT_S
        while True:
            try:
                powered = await getter()
            except Exception as e:
                log.info('adapter power query failed: %s', e)
                powered = None
            if powered or loop.time() >= end:
                return powered
            await asyncio.sleep(0.5)

    # ── "keep connected when the lid closes" ───────────────────────────────────────────────
    async def _sync_block_lock(self):
        # Hold the lid-close lock the whole time the hub runs (option on), not only while the
        # glasses are connected, so the web dashboard stays reachable with the lid shut regardless.
        want = self.keep_connected and not self.suspended
        if want and not self.block_lock.held:
            if await self.block_lock.acquire():
                self._say('Lid-close lock held: closing the lid will not suspend while the glasses are connected', 'ok')
            else:
                self._say('Could not take the lid-close lock (see hub.jsonl); the lid will still suspend', 'warn')
        elif not want and self.block_lock.held:
            await self.block_lock.release()
            self._say('Lid-close lock released')

    def on_connection_change(self, connected):
        self.connected = bool(connected)
        return self._background(self._sync_block_lock())

    def set_keep_connected(self, keep):
        self.keep_connected = bool(keep)
        return self._background(self._sync_block_lock())

    def status(self):
        return {'source': getattr(self.source, 'name', None), 'delay_lock': self.delay_lock.held,
                'lid_lock': self.block_lock.held, 'keep_connected_lid_closed': self.keep_connected,
                'suspended': self.suspended}
