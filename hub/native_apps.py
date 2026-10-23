"""Runs the glasses' built-in full-screen apps from the hub: Translate, Teleprompter, Navigation.

Each app follows the same shape (see g2/translate.py, g2/teleprompter.py, g2/navigation.py):
open it, keep it alive with a periodic heartbeat, send content, react to what the glasses send
back, close it. Only one of these apps can be open at a time on the glasses, so this controller
tracks a single "current app".

The protocol modules only build/decode bytes; this module does the timing and state. It is
driven by the hub: API handlers call open/close/content methods, and the hub's read-only frame tap
forwards every SID 0x05 / 0x06 / 0x08 frame to on_frame().
STATUS: all flows DECODED from the official app, untested live.
"""
import asyncio

from g2 import navigation as nav
from g2 import teleprompter as tp
from g2 import translate as tr

APPS = {'translate': tr, 'teleprompter': tp, 'navigation': nav}
SID_TO_APP = {tr.SID: 'translate', tp.SID: 'teleprompter', nav.SID: 'navigation'}


class NativeApps:
    def __init__(self, get_session, log, spawn=None):
        """get_session() → the connected g2 GlassesSession or None; log(message, level);
        spawn(coro, name) → Task starts a background task (the hub passes its supervisor so the
        heartbeats are cancelled when the glasses disconnect; default: asyncio.ensure_future)."""
        self._get_session = get_session
        self._log = log
        self._spawn = spawn or (lambda coro, name: asyncio.ensure_future(coro))
        self.current = None          # 'translate' | 'teleprompter' | 'navigation' | None
        self._hb_task = None
        self._pages = []             # teleprompter pages (lists of lines)
        self._nav_counter = 0
        self._waiters = []           # pending reply waiters: {sid, cmds, magic, fut}

    # ── reply waiting ───────────────────────────────────────────────────────────────────────
    ACK_TIMEOUT_S = 3.0

    def _resolve_waiter(self, sid, msg):
        """Called from on_frame (BLE callback, no awaits): hand a decoded reply to a waiter.
        Prefers a waiter whose magic matches the reply (the glasses echo the request's magic),
        else the oldest waiter for this sid/command -- so it works whether or not magic is echoed."""
        cands = [w for w in self._waiters
                 if w['sid'] == sid and msg['cmd'] in w['cmds'] and not w['fut'].done()]
        if not cands:
            return
        exact = [w for w in cands if w['magic'] == msg.get('magic')]
        (exact[0] if exact else cands[0])['fut'].set_result(msg)

    def _ack_result(self, name, resp):
        """Turn a COMM_RESP reply (or None on timeout) into an honest status dict for the route.
        acked=False means the glasses never answered -- the command is NOT confirmed."""
        cap = name.capitalize()
        if resp is None:
            self._log(f'{cap}: no reply from the glasses within {self.ACK_TIMEOUT_S:g}s '
                      '-- NOT confirmed (the glasses may not have accepted it)', 'warn')
            return {'acked': False, 'ok': False, 'error': None,
                    'detail': 'the glasses did not acknowledge the command'}
        err = resp.get('error') or 0
        if err:
            self._log(f'{cap}: glasses REJECTED the command (errorCode {err})', 'warn')
            return {'acked': True, 'ok': False, 'error': err,
                    'detail': f'the glasses rejected the command (errorCode {err})'}
        return {'acked': True, 'ok': True, 'error': 0, 'detail': None}

    # ── plumbing ────────────────────────────────────────────────────────────────────────────
    def _session(self):
        s = self._get_session()
        if s is None:
            raise RuntimeError('glasses not connected')
        return s

    async def _send(self, sid, build, label, await_cmds=None, timeout=None):
        """Send one frame. If `await_cmds` is given, arm a waiter BEFORE sending and return the
        first reply whose cmd is in that set (or None on timeout); otherwise fire-and-forget
        (returns None). The waiter is armed before the write so a fast reply can't be missed."""
        s = self._session()
        magic = s.next_magic()
        payload = build(magic)
        waiter = None
        if await_cmds:
            fut = asyncio.get_running_loop().create_future()
            waiter = {'sid': sid, 'cmds': set(await_cmds), 'magic': magic, 'fut': fut}
            self._waiters.append(waiter)
        try:
            await s.send(sid, payload)
            self._log(f'{label} pb={payload.hex()[:64]}', 'info')
            if waiter is None:
                return None
            try:
                return await asyncio.wait_for(fut, timeout or self.ACK_TIMEOUT_S)
            except asyncio.TimeoutError:
                return None
        finally:
            if waiter in self._waiters:
                self._waiters.remove(waiter)

    def _start_heartbeat(self, name, interval, build):
        self._stop_heartbeat()
        mod = APPS[name]

        async def loop():
            try:
                while True:
                    await asyncio.sleep(interval)
                    s = self._get_session()
                    if s is None:
                        return
                    await s.send(mod.SID, build(s.next_magic()))
            except asyncio.CancelledError:
                pass
            except Exception as e:
                self._log(f'{name} heartbeat stopped: {e}', 'warn')
        self._hb_task = self._spawn(loop(), f'{name}-heartbeat')

    def _stop_heartbeat(self):
        if self._hb_task and not self._hb_task.done():
            self._hb_task.cancel()
        self._hb_task = None

    async def _switch_to(self, name):
        if self.current and self.current != name:
            await self.close()
        self.current = name

    def status(self):
        return {'current': self.current, 'pages': len(self._pages)}

    # ── Translate ───────────────────────────────────────────────────────────────────────────
    async def translate_open(self, src='EN', dst='ES'):
        await self._switch_to('translate')
        resp = await self._send(tr.SID, lambda m: tr.build_open(m, src, dst),
                                f'Translate → OPEN {src}>{dst}', await_cmds=[tr.CMD_COMM_RESP])
        result = self._ack_result('translate', resp)
        if result['acked'] and not result['ok']:
            # The glasses REJECTED the open: no session exists, so don't keep a heartbeat running
            # against it (seen live: 6+ minutes of COMM_RESP FAIL) or pretend Translate is current
            # (later text would then skip the re-open).
            if self.current == 'translate':
                self.current = None
            self._stop_heartbeat()
            return result
        self._start_heartbeat('translate', tr.HEARTBEAT_INTERVAL_S, tr.build_heartbeat)
        return result

    async def translate_text(self, src_text, dst_text, final=True):
        if self.current != 'translate':
            await self.translate_open()
        resp = await self._send(tr.SID, lambda m: tr.build_text(m, src_text, dst_text, final),
                                f'Translate → TEXT {src_text[:30]!r} / {dst_text[:30]!r}'
                                f'{" (final)" if final else ""}', await_cmds=[tr.CMD_COMM_RESP])
        return self._ack_result('translate', resp)

    # ── Teleprompter ────────────────────────────────────────────────────────────────────────
    async def teleprompter_start(self, script, mode=tp.MODE_MANUAL, chars_per_line=tp.CHARS_PER_LINE):
        await self._switch_to('teleprompter')
        self._pages = tp.paginate(script, chars_per_line=chars_per_line)
        total_pages, total_lines = tp.totals(self._pages)
        await self._send(tp.SID, lambda m: tp.build_start(m, total_pages, total_lines, mode=mode),
                         f'Teleprompter → START {total_pages} page(s), {total_lines} line(s)')
        self._start_heartbeat('teleprompter', tp.HEARTBEAT_INTERVAL_S, tp.build_heartbeat)

    async def _teleprompter_page(self, page_id):
        if 0 <= page_id < len(self._pages):
            lines = self._pages[page_id]
            await self._send(tp.SID, lambda m: tp.build_page(m, page_id, lines),
                             f'Teleprompter → PAGE {page_id} ({len(lines)} lines)')
        else:
            self._log(f'Teleprompter: glasses asked for page {page_id}, script has {len(self._pages)}', 'warn')

    # ── Navigation ──────────────────────────────────────────────────────────────────────────
    async def navigation_start(self):
        await self._switch_to('navigation')
        self._nav_counter = 0
        await self._send(nav.SID, nav.build_start, 'Navigation → START')
        self._start_heartbeat('navigation', nav.HEARTBEAT_INTERVAL_S, nav.build_heartbeat)

    async def navigation_step(self, direction, **fields):
        if self.current != 'navigation':
            await self.navigation_start()
        self._nav_counter += 1
        counter = self._nav_counter
        await self._send(nav.SID, lambda m: nav.build_basic_info(m, direction, counter=counter, **fields),
                         f'Navigation → STEP {direction} {fields.get("distance") or ""} {fields.get("road") or ""}')

    async def navigation_event(self, kind):
        builders = {'recalculating': nav.build_recalculating, 'arrive': nav.build_arrive}
        await self._send(nav.SID, builders[kind], f'Navigation → {kind.upper()}')

    # ── close / incoming ────────────────────────────────────────────────────────────────────
    async def close(self):
        name, self.current = self.current, None
        self._stop_heartbeat()
        if name is None:
            return
        closers = {'translate': (tr.SID, tr.build_close), 'teleprompter': (tp.SID, tp.build_close),
                   'navigation': (nav.SID, nav.build_stop)}
        sid, build = closers[name]
        try:
            await self._send(sid, build, f'{name.capitalize()} → CLOSE')
        except RuntimeError:
            pass

    def on_frame(self, sid, pb):
        """Read-only tap entry point for SID 0x05/0x06/0x08. Must not block: replies are scheduled."""
        name = SID_TO_APP.get(sid)
        if name is None:
            return
        msg = APPS[name].decode(pb)
        self._resolve_waiter(sid, msg)
        if msg['cmd'] != APPS[name].CMD_HEARTBEAT:
            self._log(f'{name.capitalize()} ← {msg["label"]} pb={pb.hex()[:64]}', 'ok')

        if name == 'teleprompter':
            if msg['cmd'] == tp.CMD_PAGE_DATA_REQUEST and msg.get('page') is not None:
                self._spawn(self._teleprompter_page(msg['page']), 'teleprompter-page')
            elif tp.is_close(msg):
                self._ended(name)
        elif name == 'translate':
            if msg['cmd'] == tr.CMD_LANG_SWITCH_REQ:
                self._spawn(self._send(tr.SID, tr.build_lang_switch_response, 'Translate → LANG_SWITCH ok'),
                            'translate-lang-switch')
            elif msg['cmd'] == tr.CMD_NOTIFY and msg.get('value') == tr.TCMD_CLOSE:
                self._ended(name)
        elif name == 'navigation' and nav.is_exit(msg):
            self._ended(name)

    def _ended(self, name):
        if self.current == name:
            self.current = None
            self._stop_heartbeat()
            self._log(f'{name.capitalize()} closed on the glasses', 'info')
