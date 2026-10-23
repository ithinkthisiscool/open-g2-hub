"""Central auto-sync, the asyncio twin of the phone app's g2-mobile/lib/hub/sync_engine.dart.

Every piece of glasses state (settings, layout, weather, menu, tasks, calendar, news, stocks,
health, notifications) is a named *section* with a push function. Nobody presses "Send": the hub
marks a section dirty when its data changes and the engine pushes it.

* Debounce: an edit is pushed `debounce` seconds after the LAST change (default 1 s). Every edit
  moves the due time, so a burst of edits is one push, after the pause.
* Coalescing: a section marked dirty several times (or while it is already queued) is pushed
  once; a change that arrives while it is being pushed queues exactly one more push.
* One push at a time (the glasses' dashboard channel is shared), in registration order. The same
  lock is offered to the hub's legacy direct-push endpoints (exclusive()), so they never interleave
  their frames with a sync push.
* Offline queue: changes made while disconnected stay dirty and go out right after connect.
* Reconnect restore: attach() queues every `restore` section, pushed in registration order (the
  hub's order: settings, layout, weather, menu, tasks, calendar, news, stocks, health).
* Failures retry with exponential backoff (2 s, 4 s, 8 s ... capped at `max_backoff`) while
  connected; an outcome with retry=False (e.g. an invalid menu) is not retried until the next edit.
* sync_now(key) pushes at once and waits for that push's outcome (for API callers that want the
  result, e.g. scripts and the assistant's tools).

Generic over the connection context (a GlassesSession in the hub, a fake in the tests). No hub
imports: hub/sync.py registers the sections and wires the engine into the hub.
"""
import asyncio
import logging
import time
from collections import deque

log = logging.getLogger('g2hub.sync')

# Section status values (also what /api/sync reports).
IDLE, PENDING, SYNCING, SYNCED, SKIPPED, FAILED = 'idle', 'pending', 'syncing', 'synced', 'skipped', 'failed'


class SyncOutcome:
    """Result of one section push. `data` is handed back to sync_now() callers (route bodies)."""
    __slots__ = ('ok', 'message', 'data', 'retry', 'skipped')

    def __init__(self, ok, message='', data=None, retry=True, skipped=False):
        self.ok, self.message, self.data, self.retry, self.skipped = bool(ok), str(message or ''), data or {}, retry, skipped

    @classmethod
    def success(cls, message='', data=None):
        return cls(True, message, data)

    @classmethod
    def failed(cls, message, data=None, retry=True):
        return cls(False, message or 'failed', data, retry=retry)

    @classmethod
    def nothing(cls, message='nothing to send', data=None):
        """Nothing to send (feature off / no data): counts as done, but is not "synced"."""
        return cls(True, message, data, skipped=True)

    def __repr__(self):
        return f'SyncOutcome(ok={self.ok}, message={self.message!r}, skipped={self.skipped})'


def as_outcome(r):
    """Accept what a push function returns: SyncOutcome, None (= ok), bool, or (ok, message)."""
    if isinstance(r, SyncOutcome):
        return r
    if r is None:
        return SyncOutcome.success()
    if isinstance(r, tuple) and r and isinstance(r[0], bool):
        return SyncOutcome(r[0], r[1] if len(r) > 1 else '')
    return SyncOutcome.success() if r else SyncOutcome.failed('push failed')


class Section:
    def __init__(self, key, label, push, restore):
        self.key, self.label, self.push, self.restore = key, label, push, restore
        self.status = IDLE
        self.last_synced = None        # wall clock (time.time) of the last successful push
        self.last_attempt = None
        self.last_error = None
        self.last_message = ''
        self.failures = 0
        self.pushes = 0
        self.dirty_since = None        # engine clock
        # Earliest time the next push may run: the debounce after the LAST edit, or the retry
        # time after a failure. None = due now (marked before a connect, or restored).
        self.due_at = None
        self.waiters_next = []         # sync_now() futures for the next push to START
        self.waiters_now = []          # ... for the push in flight


def ago(seconds):
    """'just now', '5 min ago', '3 h ago', '2 d ago' (the phone app's wording)."""
    s = max(0, int(seconds))
    if s < 45:
        return 'just now'
    if s < 3600:
        return f'{min(59, max(1, s // 60))} min ago'
    if s < 86400:
        return f'{s // 3600} h ago'
    return f'{s // 86400} d ago'


class SyncEngine:
    def __init__(self, debounce=1.0, backoff_base=2.0, max_backoff=60.0, clock=time.monotonic, wall=time.time,
                 on_change=None, spawn=None, ctx_provider=None, history_size=50):
        """spawn(coro, name) -> Task runs the worker (the hub passes its supervisor, connection
        scope). ctx_provider() -> ctx or None, when given, is authoritative: the engine follows
        it on every mark (attaches to a new context, detaches when it is gone)."""
        self.debounce = debounce
        self.backoff_base = backoff_base
        self.max_backoff = max_backoff
        self._clock = clock
        self._wall = wall
        self.on_change = on_change
        self._spawn = spawn
        self.ctx_provider = ctx_provider
        self._sections = {}
        self.order = []                # registration order = push / restore priority
        self._dirty = set()
        self._ctx = None
        self._gen = 0
        self._task = None
        self._loop = None
        self._lock = None
        self._wake = None
        self.history = deque(maxlen=history_size)    # (key, wall time, ok, message) per push

    # ── registration and state ─────────────────────────────────────────────────────────────
    def register(self, key, push, label=None, restore=True):
        """push: async fn(ctx) -> SyncOutcome (or None/bool/(ok, msg)). Order = restore order."""
        old = self._sections.get(key)
        sec = Section(key, label or key, push, restore)
        if old is not None:
            for a in ('status', 'last_synced', 'last_attempt', 'last_error', 'last_message', 'failures', 'pushes',
                      'dirty_since', 'due_at', 'waiters_next', 'waiters_now'):
                setattr(sec, a, getattr(old, a))
        else:
            self.order.append(key)
        self._sections[key] = sec

    @property
    def connected(self):
        return self._ctx is not None

    @property
    def busy(self):
        return any(self._sections[k].status == SYNCING for k in self.order)

    def section(self, key):
        return self._sections.get(key)

    def is_dirty(self, key):
        return key in self._dirty

    @property
    def dirty(self):
        return frozenset(self._dirty)

    def _changed(self):
        if self.on_change is not None:
            try:
                self.on_change(self)
            except Exception as e:      # a UI callback must never break a push
                log.warning('sync on_change failed: %r', e)

    # ── loop-bound primitives (each asyncio.run() in the tests is a new loop) ─────────────────
    def _prims(self):
        loop = asyncio.get_running_loop()
        if self._loop is not loop:
            self._loop, self._lock, self._wake = loop, asyncio.Lock(), asyncio.Event()
            self._task = None
        return self._lock, self._wake

    @staticmethod
    def _running_loop():
        try:
            return asyncio.get_running_loop()
        except RuntimeError:
            return None

    def exclusive(self):
        """`async with engine.exclusive():` — hold the push lock (legacy direct pushes)."""
        lock, _ = self._prims()
        return lock

    # ── marking ───────────────────────────────────────────────────────────────────────────
    def _follow_provider(self):
        if self.ctx_provider is None:
            return
        try:
            ctx = self.ctx_provider()
        except Exception:
            ctx = None
        if ctx is None and self._ctx is not None:
            self.detach()
        elif ctx is not None and ctx is not self._ctx:
            self.attach(ctx, restore_all=False)

    def mark_dirty(self, key, delay=None):
        """The data behind `key` changed: push it `delay` (default: the debounce) after the last
        change, or right after the next connect. Unknown keys are ignored. Returns True if known."""
        s = self._sections.get(key)
        if s is None:
            return False
        self._follow_provider()
        wait = self.debounce if delay is None else max(0.0, delay)
        now = self._clock()
        self._dirty.add(key)
        if s.dirty_since is None:
            s.dirty_since = now
        s.due_at = now + wait
        if s.status != SYNCING:
            s.status = PENDING
        self._changed()
        self._kick()
        return True

    def push_now(self, key):
        """Push without waiting for the debounce (periodic refreshes, the device asking)."""
        return self.mark_dirty(key, delay=0.0)

    def attach(self, ctx, restore_all=True, delay=0.0):
        """Connected: queue every restore section (reconnect restore, after `delay` s) plus
        anything that was edited while offline (due at once)."""
        now = self._clock()
        if ctx is not self._ctx:
            self._stop_worker()
            self._ctx = ctx
            self._gen += 1
            for k in self._dirty:      # the offline queue: its debounce ran long ago
                self._sections[k].due_at = now
        if restore_all:
            for k in self.order:
                s = self._sections[k]
                if not s.restore:
                    continue
                due = now + max(0.0, delay)
                if k not in self._dirty or s.due_at is None or s.due_at > due:
                    s.due_at = due
                self._dirty.add(k)
                s.dirty_since = s.dirty_since or now
                if s.status != SYNCING:
                    s.status = PENDING
        self._changed()
        self._kick()

    def detach(self):
        """Disconnected: keep dirty sections queued for the next connect; fail waiting callers."""
        self._ctx = None
        self._gen += 1
        self._stop_worker()
        for s in self._sections.values():
            if s.status == SYNCING:           # its worker is being cancelled: it goes again later
                self._requeue(s)
            elif s.key in self._dirty and s.status == FAILED:
                s.status = PENDING
            self._resolve(s.waiters_next + s.waiters_now, SyncOutcome.failed('glasses disconnected'))
            s.waiters_next, s.waiters_now = [], []
        self._changed()

    def resync_all(self):
        """Developer "Force resync": every section (restore or not), now."""
        now = self._clock()
        for k in self.order:
            s = self._sections[k]
            self._dirty.add(k)
            s.dirty_since = s.dirty_since or now
            s.due_at = now
            if s.status != SYNCING:
                s.status = PENDING
        self._follow_provider()
        self._changed()
        self._kick()

    async def sync_now(self, key, timeout=30.0):
        """Push `key` now and wait for the outcome of a push that STARTS after this call (so it
        carries the caller's change). Not connected: the section stays queued and a failed
        outcome ('not connected') comes back at once."""
        s = self._sections.get(key)
        if s is None:
            return SyncOutcome.failed(f'unknown section {key}', retry=False)
        self._prims()
        self._follow_provider()
        if self._ctx is None:
            self.mark_dirty(key)
            return SyncOutcome.failed('not connected')
        fut = asyncio.get_running_loop().create_future()
        s.waiters_next.append(fut)
        self.push_now(key)
        try:
            return await asyncio.wait_for(asyncio.shield(fut), timeout)
        except asyncio.TimeoutError:
            if fut in s.waiters_next:
                s.waiters_next.remove(fut)
            return SyncOutcome.failed('timed out waiting for the glasses')

    # ── the worker ────────────────────────────────────────────────────────────────────────
    def _stop_worker(self):
        t, self._task = self._task, None
        if t is not None and not t.done():
            loop = self._running_loop()
            if loop is not None and t.get_loop() is loop:
                t.cancel()
            else:
                try:
                    t.get_loop().call_soon_threadsafe(t.cancel)
                except RuntimeError:
                    pass          # its loop is closed: nothing runs it any more

    def _kick(self):
        if self._ctx is None or self._running_loop() is None:
            return
        _, wake = self._prims()
        t = self._task
        if t is None or t.done():
            coro = self._worker(self._gen)
            name = 'sync-engine'
            self._task = self._spawn(coro, name) if self._spawn else asyncio.get_running_loop().create_task(coro, name=name)
        wake.set()

    def _next_due(self):
        now = self._clock()
        wait = None
        for k in self.order:
            if k not in self._dirty:
                continue
            due = self._sections[k].due_at
            if due is None or due <= now:
                return k, None
            w = due - now
            wait = w if wait is None else min(wait, w)
        return None, wait

    async def _worker(self, gen):
        lock, wake = self._prims()
        while gen == self._gen and self._ctx is not None:
            wake.clear()
            key, wait = self._next_due()
            if key is None:
                try:
                    await asyncio.wait_for(wake.wait(), wait)     # wait None = until the next mark
                except asyncio.TimeoutError:
                    pass
                continue
            await self._push(key, gen, lock)

    def _backoff(self, failures):
        return min(self.max_backoff, self.backoff_base * (2 ** max(0, failures - 1)))

    @staticmethod
    def _resolve(futs, outcome):
        for f in futs:
            if not f.done():
                f.set_result(outcome)

    def _requeue(self, s):
        self._dirty.add(s.key)
        s.dirty_since = s.dirty_since or self._clock()
        s.status = PENDING

    async def _push(self, key, gen, lock):
        s = self._sections[key]
        ctx = self._ctx
        self._dirty.discard(key)
        s.dirty_since = None
        s.due_at = None
        s.status = SYNCING
        s.last_attempt = self._wall()
        s.waiters_now, s.waiters_next = s.waiters_next, []
        self._changed()
        try:
            async with lock:
                r = as_outcome(await s.push(ctx))
        except asyncio.CancelledError:
            # Disconnected (or shut down) mid-push: it goes again on the next connect.
            self._requeue(s)
            self._resolve(s.waiters_now, SyncOutcome.failed('glasses disconnected'))
            s.waiters_now = []
            self._changed()
            raise
        except Exception as e:
            r = SyncOutcome.failed(str(e) or type(e).__name__)
        s.pushes += 1
        self.history.append((key, self._wall(), r.ok, r.message))
        waiters, s.waiters_now = s.waiters_now, []
        if gen != self._gen or self._ctx is not ctx:
            self._requeue(s)
            self._resolve(waiters, r)
            self._changed()
            return
        if r.ok:
            s.failures = 0
            s.last_error = None
            s.last_message = r.message
            if not r.skipped:
                s.last_synced = self._wall()
            s.status = PENDING if key in self._dirty else (SKIPPED if r.skipped else SYNCED)
        else:
            s.failures += 1
            s.last_error = r.message
            s.last_message = r.message
            log.warning('sync %s failed (%d): %s', s.label, s.failures, r.message)
            if r.retry:
                retry_at = self._clock() + self._backoff(s.failures)
                if key not in self._dirty:
                    self._dirty.add(key)
                    s.dirty_since = self._clock()
                    s.due_at = retry_at
                else:                      # edited meanwhile: not before the retry time
                    s.due_at = max(s.due_at or 0.0, retry_at)
            s.status = FAILED
        self._resolve(waiters, r)
        self._changed()

    # ── reporting ─────────────────────────────────────────────────────────────────────────
    def describe(self, key, now=None):
        """Quiet per-card status: 'Synced · just now', 'Will sync when glasses connect', ..."""
        s = self._sections.get(key)
        if s is None:
            return ''
        now = self._wall() if now is None else now
        if self._ctx is None and (key in self._dirty or s.last_synced is None) and s.status != SKIPPED:
            return 'Will sync when glasses connect'
        if s.status == PENDING:
            return 'Syncing soon…'
        if s.status == SYNCING:
            return 'Syncing…'
        if s.status == FAILED:
            return 'Not synced yet · retrying' if key in self._dirty else 'Not synced · fix and try again'
        if s.status == SKIPPED:
            return 'Nothing to sync'
        return 'Synced · ' + ago(now - s.last_synced) if s.last_synced else 'Not synced yet'

    def snapshot(self):
        now = self._wall()
        return {
            'connected': self.connected,
            'busy': self.busy,
            'sections': [{'key': k, 'label': s.label, 'status': s.status, 'dirty': k in self._dirty,
                          'restore': s.restore, 'last_synced': s.last_synced, 'last_attempt': s.last_attempt,
                          'last_error': s.last_error, 'message': s.last_message, 'failures': s.failures,
                          'pushes': s.pushes, 'text': self.describe(k, now)}
                         for k in self.order for s in (self._sections[k],)],
            'history': [{'key': k, 'ts': ts, 'ok': ok, 'message': m} for k, ts, ok, m in list(self.history)[-20:]],
        }
