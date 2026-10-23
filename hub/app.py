"""Assembles and runs the hub: directories, logging, database, API token, web server, background
loops, the glasses connection loop and the power-event monitor; clean shutdown on Ctrl+C/SIGTERM.

Entry point: python/hub/native_hub_gui.py (unchanged command line: [port, default 8766]).
Environment: G2HUB_DATA_DIR / G2HUB_CONFIG_DIR / G2HUB_STATE_DIR (hub/paths.py),
G2HUB_AUTH=0 (disable the API token), G2HUB_NO_BLE=1 (web UI only: no connection loop and no
power monitor — used to test a second instance while the real hub owns the glasses),
G2HUB_LOG_LEVEL / G2HUB_CONSOLE_LEVEL (hub/logs.py).
"""
import asyncio
import logging
import os
import signal
import socket
import sys

from aiohttp import web

from hub import auth, connection, events, hubconfig, logs, paths, power, state
from hub.events import on_event
from hub.routes import (apps, calendar, core, dev, devices, even_ai, evenhub, health, menu, news, notify, profiles,
                        settings, stocks, tasks, watchface, weather)
from hub.web.middleware import make_local_only, make_token_check

log = logging.getLogger('g2hub')

ROUTE_MODULES = (core, calendar, menu, news, weather, tasks, dev, even_ai, notify, devices, settings, apps, evenhub,
                 stocks, health, watchface, profiles)


def make_app(port, token=None):
    """The aiohttp application with every route. token=None disables the token check."""
    middlewares = [make_local_only(port)]
    if token:
        middlewares.append(make_token_check(token))
    # Room for an EvenHub package upload (base64 in JSON, see hub/routes/evenhub.py).
    app = web.Application(middlewares=middlewares, client_max_size=evenhub.MAX_REQUEST_BYTES)
    for mod in ROUTE_MODULES:
        for method, path, handler in mod.ROUTES:
            app.router.add_route(method, path, handler)
    return app


def route_table(app):
    return sorted((r.method, r.resource.canonical) for r in app.router.routes() if r.method != 'HEAD')


def _port_free(port):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind(('127.0.0.1', port))
            return True
        except OSError:
            return False


def prepare(port):
    """Everything synchronous before the event loop work starts: umask, dirs, logging, one-time
    migration, database, token. Returns the token (None when auth is disabled)."""
    os.umask(0o077)                                   # new data/log files are private (0600)
    if not _port_free(port):
        raise SystemExit(f'Port {port} is already in use (another hub running?). Nothing was changed.')
    paths.ensure_dirs()
    logs.setup(paths.log_path())
    moved = paths.migrate_legacy(log=lambda m: (log.warning(m), print(m, flush=True)))
    if moved:
        on_event(f'Moved {", ".join(moved)} to {paths.data_dir()} (one-time migration)', level='ok')
    state.init_store()
    state.init_devices()
    token = auth.get_token() if auth.auth_enabled() else None
    state.TOKEN = token
    log.info('hub starting: port=%s data=%s config=%s log=%s auth=%s', port, paths.data_dir(),
             paths.config_dir(), paths.log_path(), 'on' if token else 'OFF')
    return token


async def run_server(port, token):
    app = make_app(port, token)
    runner = web.AppRunner(app, handle_signals=False)
    await runner.setup()
    site = web.TCPSite(runner, 'localhost', port)
    await site.start()
    state.context['port'] = port
    print(f'Native Hub dashboard: http://localhost:{port}', flush=True)
    return runner


def start_power_monitor():
    cfg = hubconfig.load()
    pm = power.PowerManager(connection, source=power.default_source(),
                            keep_connected=cfg['keep_connected_lid_closed'])
    connection.listeners.append(pm.on_connection_change)
    settings.on_hub_config_changed = lambda c: pm.set_keep_connected(c['keep_connected_lid_closed'])
    state.SUP.spawn(pm.run(), name='power-monitor', scope='app')
    return pm


async def main(port=8766):
    token = prepare(port)
    runner = await run_server(port, token)
    loop = asyncio.get_running_loop()
    me = asyncio.current_task()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, me.cancel)
        except (NotImplementedError, RuntimeError):
            pass
    sup = state.SUP
    sup.spawn(news.news_refresh_loop(), name='news-refresh-loop', scope='app')
    sup.spawn(weather.weather_loop(), name='weather-loop', scope='app')
    sup.spawn(calendar.calendar_loop(), name='calendar-loop', scope='app')
    sup.spawn(calendar.calendar_sync_loop(), name='calendar-sync-loop', scope='app')
    sup.spawn(profiles.profile_scheduler_loop(), name='profile-scheduler', scope='app')
    no_ble = os.environ.get('G2HUB_NO_BLE', '').strip().lower() in ('1', 'true', 'yes')
    try:
        if no_ble:
            on_event('G2HUB_NO_BLE set: web UI only, no glasses connection', level='warn')
            await asyncio.Event().wait()
        else:
            start_power_monitor()
            evenhub.attach()             # one EvenHub app runtime per glasses connection
            await connection.connection_loop()
    except asyncio.CancelledError:
        # Ctrl+C / SIGTERM cancelled this task. Clear the pending cancellation so the cleanup
        # below (which uses asyncio.timeout internally) is not cancelled again halfway.
        while me.uncancel():
            pass
        print('Hub stopping...', flush=True)
    except BaseException as e:
        log.exception('connection_loop crashed')
        print(f'[FATAL] connection_loop crashed: {e}', flush=True)
        raise
    finally:
        n = await sup.shutdown(timeout=5.0)
        log.info('shutdown: %d background task(s) cancelled', n)
        for ws in list(events.clients):          # open pages would otherwise hold cleanup up
            try:
                await ws.close(code=1001, message=b'hub shutting down')
            except Exception:
                pass
        try:
            await asyncio.wait_for(runner.cleanup(), 10)
        except (asyncio.TimeoutError, asyncio.CancelledError) as e:
            log.warning('web server cleanup did not finish: %r', e)
        print('Hub stopped.', flush=True)
        logging.shutdown()


def run(argv=None):
    argv = sys.argv if argv is None else argv
    port = int(argv[1]) if len(argv) > 1 else 8766
    try:
        asyncio.run(main(port))
    except KeyboardInterrupt:
        print('Hub stopped.', flush=True)
    except SystemExit:
        raise
    except BaseException as e:
        import traceback
        print(f'[FATAL] Hub exited unexpectedly: {e}', flush=True)
        traceback.print_exc()
