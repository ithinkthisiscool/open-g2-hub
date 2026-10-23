"""Ownership of the hub's background tasks.

Every task the hub starts goes through spawn() and belongs to a scope:

    'app'         lives as long as the hub (news/weather/calendar refresh loops, UI-triggered
                  news refreshes). Cancelled on shutdown.
    'connection'  tied to the current glasses session (keep-alive/maintenance loop, profile
                  restore, Even AI heartbeat and turns, native-app heartbeats, quicklist paging,
                  pushes made by the refresh loops). Cancelled the moment the session drops, so
                  nothing keeps writing to a dead link or holds a lock across reconnects.

A task that fails is logged (file + Live log) instead of vanishing as "Task exception was never
retrieved"; the supervisor keeps strong references so nothing is garbage-collected mid-run.
"""
import asyncio
import logging

log = logging.getLogger('g2hub.tasks')

SCOPES = ('app', 'connection')


class Supervisor:
    def __init__(self, report=None):
        """report(message, level) is called when a task crashes (the hub passes on_event)."""
        self._tasks = {s: set() for s in SCOPES}
        self._report = report

    def spawn(self, coro, *, name, scope='app', log_errors=True):
        if scope not in self._tasks:
            coro.close()
            raise ValueError(f'unknown task scope {scope!r}')
        task = asyncio.get_running_loop().create_task(coro, name=name)
        self._tasks[scope].add(task)
        task.add_done_callback(lambda t: self._done(scope, t, log_errors))
        return task

    def _done(self, scope, task, log_errors):
        self._tasks[scope].discard(task)
        if task.cancelled() or not log_errors:
            return
        exc = task.exception()
        if exc is not None:
            log.error('task %s (%s) crashed: %r', task.get_name(), scope, exc, exc_info=exc)
            if self._report:
                try:
                    self._report(f'Background task {task.get_name()} failed: {exc}', 'err')
                except Exception:
                    pass

    def tasks(self, scope=None):
        if scope is None:
            return set().union(*self._tasks.values())
        return set(self._tasks[scope])

    async def cancel_scope(self, scope, timeout=5.0):
        """Cancel every task in `scope` and wait (up to timeout s) for them to finish.
        Returns the number of tasks that were cancelled."""
        me = asyncio.current_task()
        tasks = [t for t in self._tasks[scope] if t is not me and not t.done()]
        for t in tasks:
            t.cancel()
        if tasks:
            _, pending = await asyncio.wait(tasks, timeout=timeout)
            for t in pending:
                log.warning('task %s did not stop within %.1fs of cancel', t.get_name(), timeout)
        return len(tasks)

    async def shutdown(self, timeout=5.0):
        n = await self.cancel_scope('connection', timeout)
        return n + await self.cancel_scope('app', timeout)

    async def run_connection_job(self, coro, *, name):
        """Run `coro` as a connection-scoped task and wait for it. Returns its result, or None if
        the session dropped (scope cancelled) while it ran. Its exceptions propagate to the
        caller. If the caller itself is cancelled, the job is cancelled too."""
        task = self.spawn(coro, name=name, scope='connection', log_errors=False)
        try:
            await asyncio.wait({task})
        except asyncio.CancelledError:
            task.cancel()
            raise
        if task.cancelled():
            log.info('job %s cancelled (glasses disconnected)', name)
            return None
        return task.result()
