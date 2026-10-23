"""Smoke test for the frameless window + custom title bar on the real GTK/WebKit backend.

    .venv/bin/python desktop/tests/window_smoke.py [--port 18766] [--real-hub]

Starts the stub hub (or, with --real-hub, the real hub with G2HUB_NO_BLE=1 and throwaway data,
config and state dirs, so it never touches the glasses or your data) on a spare port, opens the
real G2 Hub window (it WILL appear on screen for a few seconds, with no tray icon), and checks
from inside the page and from GTK that:
  * the title bar is injected into the splash screen and the hub page (user script),
  * the page is shifted down by the bar and nothing overflows,
  * the page reaches Python through the js_api (hello -> state pushed back),
  * maximise / restore work (both directions) and are reflected in the page,
  * the window has no system decorations, the app id / WM_CLASS is "g2hub", icons are set,
  * window geometry is saved to the config.
With --real-hub also: the hub page built its sections, the API token works for POSTs from the
page and from the desktop's own client (hubclient.py), and the pill shows the hub's link state.
Uses a throwaway XDG config/state dir. Prints PASS/FAIL lines; exit code 0 if all passed.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
DESKTOP = HERE.parent
PY_ROOT = DESKTOP.parent

ap = argparse.ArgumentParser()
ap.add_argument('--port', type=int, default=18766)
ap.add_argument('--real-hub', action='store_true', help='use the real hub (no Bluetooth, temp dirs) instead of the stub')
args = ap.parse_args()

tmp = tempfile.mkdtemp(prefix='g2hub-smoke-')
os.environ['XDG_CONFIG_HOME'] = os.path.join(tmp, 'config')
os.environ['XDG_STATE_HOME'] = os.path.join(tmp, 'state')
if args.real_hub:
    # Inherited by the hub child; hubclient.py reads the token from G2HUB_CONFIG_DIR too.
    os.environ.update(G2HUB_NO_BLE='1', G2HUB_DATA_DIR=os.path.join(tmp, 'hub-data'),
                      G2HUB_CONFIG_DIR=os.path.join(tmp, 'hub-config'),
                      G2HUB_STATE_DIR=os.path.join(tmp, 'hub-state'))
os.environ['XDG_RUNTIME_DIR'] = os.environ.get('XDG_RUNTIME_DIR') or tmp
sys.path.insert(0, str(DESKTOP))

import chrome as gd_chrome  # noqa: E402
import g2hub_desktop as gd  # noqa: E402

results = []


def check(name, ok, detail=''):
    results.append(bool(ok))
    print(f'{"PASS" if ok else "FAIL"}  {name}' + (f'  ({detail})' if detail else ''), flush=True)


def main():
    if args.real_hub:
        hub_cmd = f'{PY_ROOT / ".venv/bin/python"} {PY_ROOT / "hub" / "native_hub_gui.py"} {{port}}'
    else:
        hub_cmd = f'{PY_ROOT / ".venv/bin/python"} {HERE / "stub_hub.py"} {{port}}'
    ns = gd.argparse.Namespace(port=args.port, url=f'http://127.0.0.1:{args.port}', browser=False,
                               minimized=False, no_tray=True, no_spawn=False, no_service=True,
                               hub_cmd=hub_cmd, timeout=15.0, check=False, system_frame=False)
    import gi
    gi.require_version('Gtk', '3.0')
    gi.require_version('Gdk', '3.0')
    from gi.repository import GLib, Gdk, Gtk  # noqa: F401
    GLib.set_prgname('g2hub')
    Gdk.set_program_class('g2hub')         # after GTK init, as g2hub_desktop.main() does
    app = gd.DesktopApp(ns)
    app.GLib = GLib
    ok, backend = gd.webview_available()
    if not ok or backend != 'gtk':
        print(f'SKIP  GTK backend unavailable: {backend}')
        return 0

    def on_gtk_sync(fn):
        box, ev = {}, threading.Event()

        def run():
            try:
                box['v'] = fn()
            except Exception as e:  # noqa: BLE001
                box['e'] = e
            ev.set()
            return False
        GLib.idle_add(run)
        ev.wait(5)
        if 'e' in box:
            raise box['e']
        return box.get('v')

    def js(expr):
        return app.window.evaluate_js(expr)

    def driver():
        try:
            deadline = time.time() + 30
            while time.time() < deadline and app.chrome is None:
                time.sleep(0.1)
            check('chrome attached on the GTK window', app.chrome is not None)
            if app.chrome is None:
                return
            time.sleep(0.8)
            # splash or hub page - either way the bar must be there
            first = js("(function(){return {bar: !!document.getElementById('g2tb'), url: location.href}})()")
            check('title bar on the first page', first and first.get('bar'), json.dumps(first))
            # wait for the hub page
            deadline = time.time() + 20
            while time.time() < deadline:
                href = js('location.href') or ''
                if href.startswith(app.url):
                    break
                time.sleep(0.3)
            time.sleep(1.5)
            info = js("""(function(){var b=document.getElementById('g2tb');
                return {bar: !!b, h: b && b.getBoundingClientRect().height, pad: getComputedStyle(document.documentElement).paddingTop,
                        scroll: document.documentElement.scrollHeight, vh: innerHeight,
                        handler: !!(window.pywebview && window.pywebview.api && window.pywebview.api.toggle_maximize),
                        pill: b && b.querySelector('.g2tb-pill').className, pillText: b && b.querySelector('.g2tb-txt').textContent,
                        url: location.href}})()""")
            check('title bar on the hub page', info and info['bar'] and info['url'].startswith(app.url), json.dumps(info))
            check('page shifted down by the bar, no overflow',
                  info and info['pad'] == f'{gd_chrome.TITLEBAR_H}px' and info['scroll'] <= info['vh'] + 1,
                  f"pad={info and info['pad']} scroll={info and info['scroll']} vh={info and info['vh']}")
            check('js_api reachable from the page', info and info['handler'])
            # hub status is pushed by the poll loop
            if args.real_hub:
                real_hub_checks(js)
            else:
                deadline = time.time() + 12
                while time.time() < deadline and 'ok' not in (js("document.querySelector('#g2tb .g2tb-pill').className") or ''):
                    time.sleep(0.3)
                pill = js("document.querySelector('#g2tb .g2tb-pill').className + ' | ' + document.querySelector('#g2tb .g2tb-pill').textContent")
                check('status pill shows the connected stub glasses', pill and ' ok' in pill and 'Work G2' in pill, pill)

            decorated = on_gtk_sync(lambda: app.chrome.native.get_decorated())
            check('window is frameless', decorated is False)
            n_icons = on_gtk_sync(lambda: len(app.chrome.native.get_icon_list() or []))
            check('window icon list set', n_icons and n_icons >= 4, f'{n_icons} sizes')
            check('program name / class', GLib.get_prgname() == 'g2hub' and Gdk.get_program_class() == 'g2hub',
                  f'{GLib.get_prgname()} / {Gdk.get_program_class()}')

            # maximise / restore through the same path the button uses (JS -> js_api -> GTK).
            # The start state may already be maximised (GNOME maximises windows that nearly fill
            # the screen), so toggle twice and expect each state to be reflected in the page.
            def is_max():
                return bool(on_gtk_sync(lambda: app.chrome.native.is_maximized()))
            start = is_max()
            for step, want in (('first toggle', not start), ('second toggle', start)):
                t0 = time.time()
                js("window.__g2tb.act('toggle_maximize')")
                deadline = time.time() + 10
                while time.time() < deadline and is_max() != want:
                    time.sleep(0.2)
                time.sleep(0.6)
                mx = is_max()
                cls = js("document.documentElement.className") or ''
                check(f'{step}: {"maximise" if want else "restore"} via title bar',
                      mx == want and (('g2tb-max' in cls) == want),
                      f'is_maximized={mx} html.class="{cls}" after {time.time() - t0:.1f}s')
            if start:     # leave it restored so a restored size gets saved
                js("window.__g2tb.act('toggle_maximize')")
                time.sleep(1.0)

            # geometry saved
            on_gtk_sync(app.save_geometry)
            saved = json.loads((Path(os.environ['XDG_CONFIG_HOME']) / 'g2hub' / 'desktop.json').read_text())
            check('window geometry saved', saved.get('window', {}).get('width'), json.dumps(saved.get('window')))

            # pywebview js_api fallback is exposed too
            api = js("Object.keys(window.pywebview && window.pywebview.api || {}).sort().join(',')")
            check('js_api exposed', api and all(n in api.split(',') for n in (
                'minimize', 'toggle_maximize', 'close', 'hide', 'quit', 'start_move', 'start_resize', 'hello')), api)
        except Exception as e:  # noqa: BLE001
            check('driver', False, repr(e))
        finally:
            app.quit()

    def real_hub_checks(js):
        shell = js("""(function(){return {nav: document.querySelectorAll('#nav .nav-btn').length,
            active: !!document.querySelector('#sections .section.active'),
            leftover: document.getElementById('cards') ? document.getElementById('cards').children.length : -1,
            title: (document.querySelector('#g2tb .g2tb-page') || {}).textContent}})()""")
        check('hub page built its sections under the title bar',
              shell and shell['nav'] == 6 and shell['active'] and shell['leftover'] == 0 and shell['title'], json.dumps(shell))
        js("window.__smoke = null; postJson('/api/settings', {keep_connected_lid_closed: false}).then(function(d){window.__smoke = d;})")
        deadline = time.time() + 5
        res = None
        while time.time() < deadline and not res:
            res = js('window.__smoke')
            time.sleep(0.2)
        check('page POST carries the API token', isinstance(res, dict) and 'hub' in res, json.dumps(res))
        try:
            client_res = app.client.post('/api/ai_reset')
        except gd.HubError as e:
            client_res = {'error': str(e)}
        check('desktop hubclient POST carries the API token', client_res == {'ok': True}, json.dumps(client_res))
        deadline = time.time() + 12
        pill = ''
        while time.time() < deadline and 'No Bluetooth' not in pill:
            pill = js("document.querySelector('#g2tb .g2tb-pill').textContent") or ''
            time.sleep(0.3)
        check('status pill shows the hub link state (no Bluetooth)', 'No Bluetooth' in pill, pill)

    threading.Thread(target=driver, daemon=True).start()
    try:
        gd._run_webview(app, 'gtk', False)
    finally:
        app._stopped.set()
        app.hub.stop()
    print(f'{sum(results)}/{len(results)} checks passed')
    return 0 if results and all(results) else 1

if __name__ == '__main__':
    sys.exit(main())
