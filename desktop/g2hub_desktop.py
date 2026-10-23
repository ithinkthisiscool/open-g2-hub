#!/usr/bin/env python3
"""G2 Hub desktop app: starts the hub server if needed and shows it in a native window + tray.

    .venv/bin/python desktop/g2hub_desktop.py            # normal start
    .venv/bin/python desktop/g2hub_desktop.py --minimized  # tray only (used by autostart)
    .venv/bin/python desktop/g2hub_desktop.py --browser    # use the default web browser instead
    .venv/bin/python desktop/g2hub_desktop.py --check      # start/attach hub, print status, exit

Hub lifecycle
  * If a hub already answers on the URL (started by hand or by the g2hub systemd user service),
    the app just attaches to it and never stops it.
  * Else, if the g2hub.service user unit is installed, it is started with systemctl (and left
    running on quit - that's what a service is for).
  * Else the hub is started as a child process and stopped when you choose Quit.

Only one instance runs per port; launching again just brings the window to the front.
"""
import argparse
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
from pathlib import Path

HERE = Path(__file__).resolve().parent
PY_ROOT = HERE.parent                                 # repo root (g2/, hub/, .venv/)
HUB_SCRIPT = PY_ROOT / 'hub' / 'native_hub_gui.py'
sys.path.insert(0, str(HERE))

from config import APP_ID, APP_NAME, Config, state_dir  # noqa: E402
from hubclient import HubClient, HubError  # noqa: E402

ICON = HERE / 'icons' / 'g2hub.svg'
ICON_PNG = HERE / 'icons' / 'png' / 'g2hub-256.png'
SERVICE = 'g2hub.service'
POLL_S = 15            # status poll while the window is hidden / tray only
POLL_VISIBLE_S = 5     # ...and while the window (and its title-bar status pill) is on screen
RESUME_GRACE_S = 120   # after the computer wakes up, "not connected" shows as "reconnecting"


def log(msg):
    print(f'[desktop] {msg}', flush=True)


def desktop_notify(summary, body=''):
    """Show a desktop notification (app name 'G2 Hub', which the notification bridge ignores)."""
    if shutil.which('notify-send'):
        try:
            icon = str(ICON_PNG if ICON_PNG.exists() else ICON)
            subprocess.Popen(['notify-send', '-a', APP_NAME, '-i', icon, summary, body],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return
        except OSError:
            pass
    log(f'{summary}: {body}')


def hub_python():
    venv = PY_ROOT / '.venv' / 'bin' / 'python'
    return str(venv) if venv.exists() else sys.executable


# --------------------------------------------------------------------------------------------
# Hub server lifecycle
# --------------------------------------------------------------------------------------------

class HubProcess:
    """mode: 'external' (already running), 'service' (systemd user unit) or 'child' (ours)."""

    def __init__(self, client, port, hub_cmd=None, allow_spawn=True, use_service=True):
        self.client = client
        self.port = port
        self.hub_cmd = hub_cmd
        self.allow_spawn = allow_spawn
        self.use_service = use_service and not hub_cmd
        self.mode = None
        self.proc = None
        self.log_path = state_dir() / 'hub.log'
        self._restarts = []
        self._lock = threading.Lock()

    # -- start --
    def ensure(self, timeout=45.0):
        """Make sure a hub answers. Raises RuntimeError with a readable reason if not."""
        self.start()
        self.wait(timeout)

    def start(self):
        """Fast part: attach, or kick off the service / child process. Call from the main thread
        (the child's parent-death signal is tied to the thread that spawns it)."""
        if self.mode:
            return
        if self.client.alive():
            self.mode = 'external'
            log(f'hub already running at {self.client.base}; attaching')
            return
        if not self.allow_spawn:
            raise RuntimeError(f'No hub is answering at {self.client.base} and starting one was disabled.')
        if self.use_service and self.port == 8766 and self._service_installed():
            log(f'starting {SERVICE} (systemd user service)')
            r = subprocess.run(['systemctl', '--user', 'start', SERVICE], capture_output=True, text=True)
            if r.returncode == 0:
                self.mode = 'service'
                return
            log(f'systemctl start failed ({r.stderr.strip()}); starting the hub directly instead')
        self._spawn()

    def wait(self, timeout=45.0):
        what = {'service': f'{SERVICE} (see: journalctl --user -u {SERVICE})'}.get(self.mode, 'the hub')
        self._wait_ready(timeout, what)

    @staticmethod
    def _service_installed():
        if not shutil.which('systemctl'):
            return False
        r = subprocess.run(['systemctl', '--user', 'cat', SERVICE], capture_output=True, text=True)
        return r.returncode == 0

    def _cmd(self):
        if self.hub_cmd:
            return [a.replace('{port}', str(self.port)) for a in self.hub_cmd.split()]
        if not HUB_SCRIPT.exists():
            raise RuntimeError(f'Hub script not found: {HUB_SCRIPT}')
        return [hub_python(), str(HUB_SCRIPT), str(self.port)]

    def _spawn(self):
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        if self.log_path.exists() and self.log_path.stat().st_size > 5_000_000:
            os.replace(self.log_path, self.log_path.with_suffix('.log.1'))
        logf = open(self.log_path, 'ab')
        logf.write(f'\n===== {time.strftime("%Y-%m-%d %H:%M:%S")} starting hub =====\n'.encode())
        logf.flush()
        env = dict(os.environ, PYTHONUNBUFFERED='1')
        cmd = self._cmd()
        log(f'starting hub: {" ".join(cmd)}  (log: {self.log_path})')
        # PR_SET_PDEATHSIG fires when the *spawning thread* exits, so only use it from the main thread.
        pre = _die_with_parent if threading.current_thread() is threading.main_thread() else None
        self.proc = subprocess.Popen(cmd, cwd=str(PY_ROOT), env=env, stdin=subprocess.DEVNULL,
                                     stdout=logf, stderr=subprocess.STDOUT, preexec_fn=pre)
        logf.close()
        self.mode = 'child'

    def _wait_ready(self, timeout, what):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.client.alive(timeout=1.0):
                log(f'hub ready at {self.client.base}')
                return
            if self.proc is not None and self.proc.poll() is not None:
                raise RuntimeError(f'{what} exited during start-up (code {self.proc.returncode}).')
            time.sleep(0.4)
        raise RuntimeError(f'{what} did not answer within {int(timeout)} s.')

    def log_tail(self, n=25):
        try:
            with open(self.log_path, 'rb') as f:
                f.seek(0, 2)
                f.seek(max(0, f.tell() - 20000))
                return '\n'.join(f.read().decode(errors='replace').splitlines()[-n:])
        except OSError:
            return ''

    # -- watchdog: restart our own child if it crashes (max 3 times per 5 minutes) --
    def check_child(self):
        with self._lock:
            if self.mode != 'child' or self.proc is None or self.proc.poll() is None:
                return None
            code = self.proc.returncode
            now = time.monotonic()
            self._restarts = [t for t in self._restarts if now - t < 300]
            if len(self._restarts) >= 3:
                return f'The hub keeps crashing (exit code {code}); not restarting. Log: {self.log_path}'
            self._restarts.append(now)
            log(f'hub exited unexpectedly (code {code}); restarting')
            self._spawn()
            return None

    # -- stop --
    def stop(self):
        with self._lock:
            if self.mode != 'child' or self.proc is None:
                if self.mode in ('external', 'service'):
                    log(f'leaving the {self.mode} hub running')
                return
            p, self.proc = self.proc, None
        if p.poll() is not None:
            return
        log('stopping hub...')
        # SIGINT first: the hub turns it into KeyboardInterrupt and closes BLE links cleanly.
        for sig, wait in ((signal.SIGINT, 6), (signal.SIGTERM, 4), (signal.SIGKILL, 2)):
            try:
                p.send_signal(sig)
                p.wait(wait)
                log(f'hub stopped (exit code {p.returncode})')
                return
            except subprocess.TimeoutExpired:
                continue
            except ProcessLookupError:
                return


def _die_with_parent():
    """Child pre-exec: get SIGTERM if the launcher dies without cleaning up (Linux prctl)."""
    try:
        import ctypes
        ctypes.CDLL('libc.so.6', use_errno=True).prctl(1, signal.SIGTERM)   # PR_SET_PDEATHSIG
    except Exception:  # noqa: BLE001
        pass


# --------------------------------------------------------------------------------------------
# Single instance (per port): a unix socket in $XDG_RUNTIME_DIR
# --------------------------------------------------------------------------------------------

class SingleInstance:
    def __init__(self, port):
        rt = os.environ.get('XDG_RUNTIME_DIR') or str(state_dir())
        self.path = Path(rt) / f'{APP_ID}-desktop-{port}.sock'
        self.sock = None

    def signal_existing(self, message=b'show'):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(1.0)
        try:
            s.connect(str(self.path))
            s.sendall(message + b'\n')
            return True
        except OSError:
            return False
        finally:
            s.close()

    def listen(self, on_message):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        try:
            self.path.unlink()
        except FileNotFoundError:
            pass
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(str(self.path))
        os.chmod(self.path, 0o600)
        self.sock.listen(4)

        def loop():
            while self.sock:
                try:
                    conn, _ = self.sock.accept()
                except OSError:
                    return
                with conn:
                    conn.settimeout(1.0)
                    try:
                        msg = conn.recv(1024).strip().decode(errors='replace')
                    except OSError:
                        continue
                    on_message(msg)

        threading.Thread(target=loop, name='single-instance', daemon=True).start()

    def close(self):
        if self.sock:
            s, self.sock = self.sock, None
            s.close()
            try:
                self.path.unlink()
            except FileNotFoundError:
                pass


# --------------------------------------------------------------------------------------------
# Status polling
# --------------------------------------------------------------------------------------------

def _hub_says_reconnecting(status):
    """The hub reports its link state in GET /api/status: {"link": "reconnecting"} for a while
    after the link dropped (hub/routes/core.py link_state). Older spellings are accepted too."""
    if not isinstance(status, dict):
        return False
    if status.get('reconnecting') or status.get('resuming'):
        return True
    for k in ('state', 'link', 'link_state', 'phase', 'ble'):
        v = status.get(k)
        if isinstance(v, str) and v.lower() in ('reconnecting', 'resuming', 'waking', 'resume'):
            return True
    return False


def poll_state(client, resumed_at=None):
    """One snapshot for the tray and title bar: reachability, connection, devices, battery.
    resumed_at: time.monotonic() of the last wake-up from suspend (None if unknown)."""
    st = {'reachable': False}
    try:
        d = client.devices()
    except HubError:
        return st
    st.update(reachable=True, connected=bool(d.get('connected')), devices=d.get('devices') or [],
              active=d.get('active'))
    if not st['connected']:
        recent = resumed_at is not None and time.monotonic() - resumed_at < RESUME_GRACE_S
        hub_says = False
        try:
            status = client.status()
            hub_says = _hub_says_reconnecting(status)
            # 'paused' (adapter off / suspend) and 'disabled' (G2HUB_NO_BLE) get their own text.
            if isinstance(status, dict) and isinstance(status.get('link'), str):
                st['link'] = status['link']
                st['paused'] = [str(r) for r in status.get('paused') or []]
        except HubError:
            pass
        st['reconnecting'] = bool(hub_says or (recent and st.get('link') not in ('paused', 'disabled')))
    act = next((x for x in st['devices'] if x.get('id') == st['active']), None)
    if act:
        st['active_name'] = act.get('name') or act.get('pair_id')
    try:
        s = (client.settings() or {}).get('status') or {}
        for k in ('battery', 'charging', 'case_battery', 'worn'):
            if s.get(k) is not None:
                st[k] = s[k]
    except HubError:
        pass
    return st


# --------------------------------------------------------------------------------------------
# Quick send: flash a short note onto the glasses without opening the web UI.
#
# The dependable path is the tray "Quick send…" action; a system-wide hotkey is best-effort and
# opt-in (see hotkey_support() for the honest story about why). Both routes funnel through the
# same quick_send() below, which reuses the hub's POST /api/notify_send (via HubClient.notify) -
# no new hub route, no serial/flash, no BLE here.
# --------------------------------------------------------------------------------------------

QUICK_SEND_TITLE = 'Quick note'   # notification title shown on the glasses for a quick-send note
DEFAULT_HOTKEY = 'ctrl+alt+g'     # used when G2HUB_QUICKSEND_HOTKEY is just turned on ("1"/"on")


def quicksend_preset():
    """Optional fixed note (G2HUB_QUICKSEND_PRESET). When set, the hotkey sends it instantly and
    the tray gains a one-click 'Send preset note' item. Empty/unset means 'prompt for the text'."""
    return (os.environ.get('G2HUB_QUICKSEND_PRESET') or '').strip()


def quick_send(client, message, title=QUICK_SEND_TITLE):
    """POST a short note to the hub's /api/notify_send so it appears on the glasses.

    Pure and side-effect-light (no GUI, no desktop_notify): takes any object with a .notify(title,
    message) method - the real HubClient, or a stand-in in tests - and returns (ok, detail).
    Never raises: an empty note or a HubError (e.g. glasses not connected) becomes (False, reason)."""
    message = (message or '').strip()
    if not message:
        return False, 'empty message'
    try:
        resp = client.notify(title, message)
    except HubError as e:
        return False, str(e)
    detail = ''
    if isinstance(resp, dict):
        detail = resp.get('result') or ''
    return True, detail or 'sent'


def _globalshortcuts_portal_present():
    """True if the XDG desktop portal advertises the GlobalShortcuts interface (the only sanctioned
    system-wide-shortcut path on Wayland). Side-effect free: just introspects the portal object."""
    try:
        from gi.repository import Gio, GLib
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        res = bus.call_sync('org.freedesktop.portal.Desktop', '/org/freedesktop/portal/desktop',
                            'org.freedesktop.DBus.Introspectable', 'Introspect', None,
                            GLib.VariantType('(s)'), Gio.DBusCallFlags.NONE, 1000, None)
        return 'org.freedesktop.portal.GlobalShortcuts' in res.unpack()[0]
    except Exception:  # noqa: BLE001
        return False


def hotkey_support():
    """Honest, side-effect-free check of whether a *true* system-wide hotkey is feasible here.

    Returns (mode, detail):
      'xlib'        - X11 session with python-xlib: a real global key grab works.
      'portal'      - Wayland with an XDG GlobalShortcuts portal: best-effort only. The compositor
                      makes the user confirm the binding in a system dialog and may ignore it, so it
                      is never guaranteed - the tray action stays the dependable path.
      'unavailable' - no feasible global hotkey (plain Wayland, or X11 without python-xlib). Use the
                      tray 'Quick send…' action.
    """
    session = (os.environ.get('XDG_SESSION_TYPE') or '').lower()
    on_wayland = bool(os.environ.get('WAYLAND_DISPLAY')) or session == 'wayland'
    on_x11 = session == 'x11' or (not session and os.environ.get('DISPLAY') and not on_wayland)
    if on_x11:
        try:
            import Xlib  # noqa: F401
            return 'xlib', 'X11 session; a global key grab via python-xlib is available'
        except ImportError:
            return 'unavailable', ('X11 session but python-xlib is not installed (pip install '
                                   'python-xlib); use the tray "Quick send…" action')
    if _globalshortcuts_portal_present():
        return 'portal', ('Wayland: a GlobalShortcuts portal is present, but it needs you to confirm '
                          'the shortcut in a system dialog and the compositor may not honour it, so '
                          'it is best-effort; the tray "Quick send…" action is the dependable path')
    return 'unavailable', ('Wayland session with no global-shortcuts portal: a true system-wide '
                           'hotkey is not possible here - use the tray "Quick send…" action')


def _parse_combo(combo, XK):
    """'ctrl+alt+g' -> (X modifier mask, keysym). Raises ValueError on an unknown key."""
    from Xlib import X
    names = {'ctrl': X.ControlMask, 'control': X.ControlMask, 'alt': X.Mod1Mask, 'mod1': X.Mod1Mask,
             'shift': X.ShiftMask, 'super': X.Mod4Mask, 'win': X.Mod4Mask, 'meta': X.Mod4Mask}
    mods, key = 0, None
    for tok in combo.lower().split('+'):
        tok = tok.strip()
        if tok in names:
            mods |= names[tok]
        elif tok:
            key = tok
    if not key:
        raise ValueError(f'no key in hotkey {combo!r}')
    keysym = XK.string_to_keysym(key if len(key) > 1 else key)
    if not keysym:
        raise ValueError(f'unknown key {key!r} in hotkey {combo!r}')
    return mods, keysym


class XlibHotkey:
    """A real system-wide hotkey on X11 via python-xlib (only reached when hotkey_support()=='xlib').
    Grabs the combo on the root window and calls on_trigger() from a daemon thread on each press."""

    def __init__(self, combo, on_trigger, log=lambda _m: None):
        self.combo, self.on_trigger, self.log = combo, on_trigger, log
        self._stop = threading.Event()
        self._disp = None

    def start(self):
        from Xlib import X, XK
        from Xlib.display import Display
        self._disp = Display()
        root = self._disp.screen().root
        mods, keysym = _parse_combo(self.combo, XK)
        self._keycode = self._disp.keysym_to_keycode(keysym)
        if not self._keycode:
            raise ValueError(f'no keycode for {self.combo!r}')
        # Also grab with NumLock/CapsLock so those toggles don't swallow the shortcut.
        for extra in (0, X.Mod2Mask, X.LockMask, X.Mod2Mask | X.LockMask):
            root.grab_key(self._keycode, mods | extra, True, X.GrabModeAsync, X.GrabModeAsync)
        root.change_attributes(event_mask=X.KeyPressMask)
        self._disp.sync()
        threading.Thread(target=self._loop, name='quick-send-hotkey', daemon=True).start()

    def _loop(self):
        from Xlib import X
        while not self._stop.is_set():
            if self._disp.pending_events():
                ev = self._disp.next_event()
                if ev.type == X.KeyPress and ev.detail == self._keycode:
                    try:
                        self.on_trigger()
                    except Exception as e:  # noqa: BLE001
                        self.log(f'quick-send hotkey handler error: {e}')
            else:
                time.sleep(0.05)

    def stop(self):
        self._stop.set()
        try:
            if self._disp is not None:
                self._disp.close()
        except Exception:  # noqa: BLE001
            pass


# Palette and font copied from the hub page's :root block (hub/web/page.py) so every
# desktop-side surface (splash, error screen, icons) looks like the hub itself.
HUB_CSS_VARS = """
    --bg: #000000; --panel: #061006; --panel2: #0a1a0a; --border: #1a5c1a;
    --text: #4dff7a; --dim: #5fb87f; --bright: #a8ffc0; --red: #ff6b6b; --amber: #ffd23f;
    --glow: 0 0 4px rgba(77,255,122,0.35);"""
HUB_FONT = "'JetBrains Mono', ui-monospace, 'SF Mono', Menlo, Consolas, monospace"
WINDOW_BG = '#000000'


def splash_html(title, body, detail='', state='starting', chrome_inline=False):
    """Start-up / error screen in the hub's look. state: 'starting' (amber, spinner) or 'error'.
    In the frameless window the custom title bar (chrome.py) is added to this page too, and its
    status pill shows STARTING / HUB OFFLINE; chrome_inline embeds it here instead of relying on
    the WebKit user script (only needed off GTK)."""
    def esc(t):
        return (t or '').replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
    err = state == 'error'
    pill = ('<span class="dot err"></span>Hub offline' if err else '<span class="dot wait"></span>Starting')
    head_extra = ''
    if chrome_inline:
        from chrome import inline_html
        head_extra = inline_html()
    extra = f'<pre>{esc(detail)}</pre>' if detail else ''
    if not err:
        extra += '<div class="bar"><i></i></div>'
    return f'''<!doctype html><html><head><meta charset="utf-8"><title>G2 Hub</title>
<link rel="stylesheet" media="print" onload="this.media='all'"
      href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;700&display=swap">
<style>
  :root {{{HUB_CSS_VARS}
  }}
  * {{ box-sizing: border-box; }}
  html, body {{ height: 100%; }}
  body {{
    margin: 0; display: flex; align-items: center; justify-content: center;
    background:
      repeating-linear-gradient(0deg, rgba(0,255,65,0.025) 0px, rgba(0,255,65,0.025) 1px, transparent 1px, transparent 3px),
      radial-gradient(1400px 700px at 50% -10%, #061206 0%, var(--bg) 60%);
    color: var(--text); font-family: {HUB_FONT}; font-size: 14px; line-height: 1.5;
  }}
  .card {{ width: min(760px, calc(100vw - 48px)); background: var(--panel); border: 1px solid var(--border);
          border-radius: 4px; padding: 26px 28px; box-shadow: 0 0 40px rgba(77,255,122,0.06); }}
  header {{ display: flex; align-items: center; gap: 14px; border-bottom: 1px solid var(--border);
           padding-bottom: 16px; margin-bottom: 18px; }}
  .logo {{ width: 42px; height: 42px; border-radius: 4px; background: var(--panel2); border: 1px solid var(--text);
          display: flex; align-items: center; justify-content: center; font-size: 20px; box-shadow: var(--glow);
          color: var(--bright, #4dff7a); }}
  h1 {{ font-size: 19px; font-weight: 700; margin: 0; letter-spacing: 0.04em; text-shadow: var(--glow);
       text-transform: uppercase; }}
  .tag {{ font-size: 12px; color: var(--dim); margin-top: 3px; }}
  .conn {{ margin-left: auto; display: flex; align-items: center; gap: 8px; font-size: 12px; color: var(--dim);
          background: var(--bg); border: 1px solid var(--border); padding: 7px 14px; border-radius: 3px;
          text-transform: uppercase; letter-spacing: 0.05em; white-space: nowrap; }}
  .dot {{ width: 8px; height: 8px; border-radius: 50%; }}
  .dot.wait {{ background: var(--amber); box-shadow: 0 0 8px var(--amber); animation: blink 1.2s steps(2) infinite; }}
  .dot.err {{ background: var(--red); box-shadow: 0 0 8px var(--red); }}
  p {{ margin: 0 0 14px; color: var(--bright); }}
  p.hint {{ color: var(--dim); font-size: 12px; }}
  pre {{ margin: 0; background: var(--bg); color: var(--dim); border: 1px solid var(--border); border-radius: 3px;
        padding: 12px 14px; max-height: 46vh; overflow: auto; font: 12px/1.45 {HUB_FONT}; white-space: pre-wrap; }}
  .bar {{ height: 3px; background: var(--panel2); border: 1px solid var(--border); overflow: hidden; }}
  .bar i {{ display: block; height: 100%; width: 30%; background: var(--text); box-shadow: var(--glow);
           animation: slide 1.4s ease-in-out infinite; }}
  @keyframes slide {{ 0% {{ transform: translateX(-100%); }} 100% {{ transform: translateX(340%); }} }}
  @keyframes blink {{ 50% {{ opacity: 0.35; }} }}
  /* inside the app window the title bar already shows the status pill */
  html.g2tb-on .card .conn {{ display: none; }}
  html, body {{ -webkit-user-select: none; user-select: none; cursor: default; }}
  pre {{ -webkit-user-select: text; user-select: text; cursor: text; }}
</style>{head_extra}</head><body><div class="card">
  <header>
    <div class="logo">&gt;_</div>
    <div><h1>G2 Hub</h1><div class="tag">Even Realities G2 control centre</div></div>
    <div class="conn">{pill}</div>
  </header>
  <p>&gt; {esc(title)}</p>
  <p class="hint">{esc(body)}</p>
  {extra}
</div></body></html>'''


# --------------------------------------------------------------------------------------------
# The application
# --------------------------------------------------------------------------------------------

class DesktopApp:
    def __init__(self, args):
        self.args = args
        self.url = args.url
        self.port = urllib.parse.urlsplit(self.url).port or 80
        self.client = HubClient(self.url)
        self.cfg = Config()
        self.hub = HubProcess(self.client, self.port, hub_cmd=args.hub_cmd,
                              allow_spawn=not args.no_spawn and _is_local(self.url),
                              use_service=not args.no_service)
        self.window = None
        self.chrome = None             # chrome.WindowChrome when the frameless window is used
        self.tray = None
        self.tray_ok = False
        self.resumed_at = None         # time.monotonic() of the last wake from suspend
        self._geom_timer = None
        self.bridge = None
        self.hotkey = None             # XlibHotkey when a real global hotkey is registered
        self.GLib = None
        self.quitting = False
        self._poke = threading.Event()
        self._stopped = threading.Event()
        self._scanning = False
        self.start_error = None
        self.start_error_shown = False

    # -- helpers that are safe from any thread --
    def on_gtk(self, fn, *a):
        if self.GLib:
            self.GLib.idle_add(lambda: (fn(*a), False)[1])
        else:
            fn(*a)

    def refresh_soon(self):
        self._poke.set()

    # -- tray callbacks --
    def open(self, token=None):
        """Show and focus the window. token: XDG activation / startup-notification token of the
        launch that asked for it (lets Wayland compositors hand focus over)."""
        if self.window is not None:
            self.window.show()
            self.window.restore()
            if token and self.chrome and self.chrome.native is not None:
                try:
                    self.chrome.native.set_startup_id(token)
                    self.chrome.native.present()
                except Exception:  # noqa: BLE001
                    pass
        else:
            _open_browser(self.url)

    def hide_window(self):
        """Ctrl+W / close button: hide to the tray, or minimise when there is no tray."""
        if self.window is None:
            return
        self.save_geometry()
        if self.tray_ok and self.tray is not None:
            self.window.hide()
        else:
            self.window.minimize()

    # -- window geometry (GTK thread) --
    def geometry_changed(self):
        """configure/state events: save a moment after the last change."""
        if self.GLib is None:
            return
        if self._geom_timer:
            self.GLib.source_remove(self._geom_timer)

        def fire():
            self._geom_timer = None
            self.save_geometry()
            return False
        self._geom_timer = self.GLib.timeout_add(800, fire)

    def save_geometry(self):
        w = self.chrome.native if self.chrome else None
        if w is None or not w.get_realized():
            return
        try:
            maximized = bool(w.is_maximized())
            geo = dict(self.cfg['window'] or {})
            geo['maximized'] = maximized
            if not maximized and not self.chrome.snapshot().get('fullscreen'):
                width, height = w.get_size()
                geo.update(width=int(width), height=int(height))
                if _is_x11():
                    x, y = w.get_position()
                    geo.update(x=int(x), y=int(y))
            if geo != self.cfg['window']:
                self.cfg.data['window'] = geo
                self.cfg.save()
        except Exception as e:  # noqa: BLE001
            log(f'could not save window geometry: {e}')

    # -- suspend / resume (logind), so the title bar can say "reconnecting" --
    def watch_resume(self):
        try:
            from gi.repository import Gio
            bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        except Exception as e:  # noqa: BLE001
            log(f'no suspend/resume notifications ({e})')
            return

        def on_sleep(_conn, _sender, _path, _iface, _signal, params):
            going_to_sleep = bool(params.unpack()[0])
            if not going_to_sleep:
                log('computer woke up; glasses will reconnect')
                self.resumed_at = time.monotonic()
                self.refresh_soon()
        self._sleep_bus = bus
        bus.signal_subscribe('org.freedesktop.login1', 'org.freedesktop.login1.Manager', 'PrepareForSleep',
                             '/org/freedesktop/login1', None, Gio.DBusSignalFlags.NONE, on_sleep)

    def scan(self):
        if self._scanning:
            return
        self._scanning = True
        if self.tray:
            self.on_gtk(self.tray.set_scanning, True)

        def work():
            desktop_notify('Scanning for G2 glasses...', 'Make sure the glasses are out of the case and nearby.')
            try:
                found = self.client.scan().get('found') or []
                new = [f for f in found if not f.get('known_id')]
                if not found:
                    desktop_notify('No glasses found', 'Glasses that are already connected do not show up in a scan.')
                elif new:
                    desktop_notify(f'Found {len(new)} new pair(s) of glasses',
                                   'Open G2 Hub > Glasses to add them.')
                    self.on_gtk(self.open)
                else:
                    desktop_notify(f'Found {len(found)} pair(s)', 'All of them are already saved.')
            except HubError as e:
                desktop_notify('Scan failed', str(e))
            finally:
                self._scanning = False
                if self.tray:
                    self.on_gtk(self.tray.set_scanning, False)
                self.refresh_soon()

        threading.Thread(target=work, name='scan', daemon=True).start()

    def select(self, dev_id):
        def work():
            try:
                self.client.select(dev_id)
            except HubError as e:
                desktop_notify('Could not switch glasses', str(e))
            self.refresh_soon()
        threading.Thread(target=work, name='select', daemon=True).start()

    # -- quick send --------------------------------------------------------------------------
    def send_note(self, message, title=None):
        """Flash a short note on the glasses via the hub, with a desktop-notification receipt.
        Safe to call from any worker thread. Returns True on success."""
        ok, detail = quick_send(self.client, message, title or QUICK_SEND_TITLE)
        if ok:
            desktop_notify('Sent to glasses', (message or '').strip())
        else:
            desktop_notify('Quick send failed', detail)
        return ok

    def send_preset(self):
        """Tray / hotkey: send the configured preset note instantly (no prompt)."""
        preset = quicksend_preset()
        if preset:
            threading.Thread(target=self.send_note, args=(preset,), name='quick-send', daemon=True).start()

    def quick_send_prompt(self):
        """Tray action: pop a tiny entry, then send the typed note. The dependable quick-send path."""
        if self.GLib is None:                       # no GTK (e.g. --browser without a tray)
            preset = quicksend_preset()
            if preset:
                self.send_preset()
            else:
                desktop_notify('Quick send needs the app window',
                               'Set G2HUB_QUICKSEND_PRESET to send a fixed note without a dialog.')
            return
        self.on_gtk(self._quick_send_dialog)

    def _quick_send_dialog(self):
        from gi.repository import Gtk
        dlg = Gtk.Dialog(title='Quick send to glasses')
        dlg.add_button('Cancel', Gtk.ResponseType.CANCEL)
        send = dlg.add_button('Send', Gtk.ResponseType.OK)
        try:
            send.get_style_context().add_class('suggested-action')
        except Exception:  # noqa: BLE001
            pass
        dlg.set_default_response(Gtk.ResponseType.OK)
        box = dlg.get_content_area()
        box.set_spacing(8)
        box.set_border_width(12)
        box.add(Gtk.Label(label='Note to flash on the glasses:', xalign=0))
        entry = Gtk.Entry()
        entry.set_activates_default(True)
        entry.set_width_chars(36)
        preset = quicksend_preset()
        if preset:
            entry.set_text(preset)
        box.add(entry)
        dlg.show_all()
        resp = dlg.run()
        text = entry.get_text().strip()
        dlg.destroy()
        if resp == Gtk.ResponseType.OK and text:
            threading.Thread(target=self.send_note, args=(text,), name='quick-send', daemon=True).start()
        return False

    def on_hotkey(self):
        """Global-hotkey trigger (best-effort): send the preset if set, else open the prompt."""
        if quicksend_preset():
            self.send_preset()
        else:
            self.quick_send_prompt()

    def start_global_hotkey(self):
        """Opt-in, best-effort system-wide shortcut. OFF unless G2HUB_QUICKSEND_HOTKEY is set
        (to a combo like 'ctrl+alt+g', or just '1'/'on' for the default). Never required: on
        Wayland a true global hotkey usually is not possible, so the tray action stays the path."""
        spec = os.environ.get('G2HUB_QUICKSEND_HOTKEY')
        if not spec:
            return
        combo = DEFAULT_HOTKEY if spec.lower() in ('1', 'true', 'yes', 'on', 'default') else spec
        mode, detail = hotkey_support()
        log(f'global hotkey: {detail}')
        if mode == 'xlib':
            try:
                self.hotkey = XlibHotkey(combo, self.on_hotkey, log=log)
                self.hotkey.start()
                log(f'global hotkey {combo} registered (X11)')
            except Exception as e:  # noqa: BLE001
                self.hotkey = None
                log(f'could not register global hotkey ({e}); use the tray "Quick send…" action')
        else:
            log(f'no global hotkey registered; use the tray "Quick send…" action')

    def set_forwarding(self, on):
        from notify_bridge import NotificationBridge
        try:
            if on:
                if self.bridge is None:
                    self.bridge = NotificationBridge(self.client, self.cfg, log=log)
                self.bridge.start()
                if not self.cfg['allow_apps']:
                    desktop_notify('Notification forwarding is on',
                                   'No apps are allowed yet. Add app names to "allow_apps" in '
                                   f'{self.cfg.path} (see docs/desktop.md).')
            elif self.bridge:
                self.bridge.stop()
            self.cfg.set('forward_notifications', bool(on))
        except Exception as e:  # noqa: BLE001
            desktop_notify('Notification forwarding unavailable', str(e))
            self.cfg.set('forward_notifications', False)
            if self.tray:
                self.on_gtk(self.tray.set_forwarding, False)

    def quit(self):
        if self.quitting:
            return
        self.quitting = True
        log('quitting')
        self._stopped.set()
        self._poke.set()
        if self.bridge:
            self.bridge.stop()
        if self.hotkey:
            self.hotkey.stop()
        if self.window is not None:
            if self.chrome is not None and self.GLib is not None:
                if threading.current_thread() is threading.main_thread():
                    self.save_geometry()
                else:
                    done = threading.Event()
                    self.GLib.idle_add(lambda: (self.save_geometry(), done.set(), False)[2])
                    done.wait(1.0)
            self.window.destroy()          # makes webview.start() return in main()
        elif self.GLib:
            from gi.repository import Gtk
            self.on_gtk(Gtk.main_quit)

    # -- background work --
    def poll_loop(self):
        crash_reported = False
        while not self._stopped.is_set():
            msg = self.hub.check_child()
            if msg and not crash_reported:
                crash_reported = True
                desktop_notify('G2 Hub stopped working', msg)
            st = poll_state(self.client, self.resumed_at)
            if st.get('connected'):
                self.resumed_at = None
            if self.tray:
                self.on_gtk(self.tray.update, st)
            if self.chrome:
                from chrome import status_view
                self.chrome.set_status(status_view(st, 'error' if self.start_error_shown else None))
            visible = self.chrome is not None and self.chrome.visible
            self._poke.wait(POLL_VISIBLE_S if visible else POLL_S)
            self._poke.clear()

    def start_services(self, want_tray):
        """Tray + poller + optional notification bridge. Call once GTK is (about to be) running."""
        if want_tray:
            from tray import Tray
            cbs = dict(open=self.open, scan=self.scan, select=self.select,
                       quick_send=self.quick_send_prompt,
                       set_forwarding=lambda on: threading.Thread(target=self.set_forwarding, args=(on,),
                                                                  daemon=True).start(),
                       quit=self.quit)
            if quicksend_preset():
                cbs['quick_send_preset'] = self.send_preset

            def make():
                try:
                    self.tray = Tray(cbs, forwarding=self.cfg['forward_notifications'])
                except Exception as e:  # noqa: BLE001
                    log(f'tray unavailable: {e}')
                self.refresh_soon()
            self.on_gtk(make)
        if self.cfg['forward_notifications']:
            threading.Thread(target=self.set_forwarding, args=(True,), daemon=True).start()
        self.start_global_hotkey()                 # opt-in; no-op unless G2HUB_QUICKSEND_HOTKEY is set
        threading.Thread(target=self.poll_loop, name='poll', daemon=True).start()

    def bootstrap(self, want_tray):
        """Runs in a worker thread once the window exists: start the hub, then load the UI."""
        try:
            if self.start_error:
                raise self.start_error
            self.hub.wait(self.args.timeout)
        except RuntimeError as e:
            log(f'hub failed to start: {e}')
            self.start_error_shown = True
            if self.chrome:
                from chrome import status_view
                self.chrome.set_status(status_view({}, 'error'))
            if self.window is not None:
                self.window.load_html(splash_html(
                    'G2 Hub could not start', str(e) + ' Details from the hub log are below. Quit from the '
                    'tray (or close this window) and start G2 Hub again.', self.hub.log_tail(), state='error'))
            desktop_notify('G2 Hub could not start', str(e))
            self.start_services(want_tray)   # tray still offers Quit
            return
        if self.window is not None:
            self.window.load_url(self.url)
        self.start_services(want_tray)


def _is_local(url):
    return urllib.parse.urlsplit(url).hostname in ('127.0.0.1', 'localhost', '::1')


def _open_browser(url):
    for cmd in (['xdg-open', url], ['gio', 'open', url]):
        if shutil.which(cmd[0]):
            subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return
    import webbrowser
    webbrowser.open(url)


def _reexec_with_venv(argv):
    """pywebview lives in the repo's .venv. Started with another interpreter (e.g. system
    python3), the window cannot open and the app would fall back to the browser, so restart
    under the venv's python instead. No-op when already there or when the venv is missing."""
    venv_py = Path(__file__).resolve().parent.parent / '.venv' / 'bin' / 'python'
    if not venv_py.exists() or Path(sys.prefix).resolve() == venv_py.parent.parent.resolve():
        return
    if webview_available()[0]:
        return
    log(f'pywebview not available in {sys.executable}; restarting with {venv_py}')
    os.execv(str(venv_py), [str(venv_py), str(Path(__file__).resolve())]
             + list(sys.argv[1:] if argv is None else argv))


def webview_available():
    try:
        import webview  # noqa: F401
        from webview.platforms import gtk  # noqa: F401  (imports GTK + WebKit2GTK)
        return True, 'gtk'
    except Exception as e:  # noqa: BLE001
        gtk_err = e
    try:
        from webview.platforms import qt  # noqa: F401
        return True, 'qt'
    except Exception:  # noqa: BLE001
        return False, f'pywebview GTK backend unavailable ({gtk_err})'


# --------------------------------------------------------------------------------------------

def run_check(app):
    """--check: start/attach, print one status snapshot as JSON, stop what we started."""
    code = 0
    try:
        app.hub.ensure(timeout=app.args.timeout)
        st = poll_state(app.client)
        from tray import describe
        st['summary'] = describe(st)[0]
        st['hub_mode'] = app.hub.mode
        print(json.dumps(st, indent=2))
    except RuntimeError as e:
        print(json.dumps({'error': str(e), 'log_tail': app.hub.log_tail(10)}, indent=2))
        code = 1
    finally:
        app.hub.stop()
    return code


def main(argv=None):
    ap = argparse.ArgumentParser(prog='g2hub-desktop', description='G2 Hub desktop app')
    ap.add_argument('--port', type=int, default=8766, help='hub port (default 8766)')
    ap.add_argument('--url', help='hub base URL (default http://127.0.0.1:<port>)')
    ap.add_argument('--browser', action='store_true', help='open the UI in the default web browser')
    ap.add_argument('--minimized', action='store_true', help='start in the tray without a window')
    ap.add_argument('--no-tray', action='store_true', help='no tray icon (closing the window quits)')
    ap.add_argument('--no-spawn', action='store_true', help='never start a hub; only attach to a running one')
    ap.add_argument('--no-service', action='store_true', help='do not use the g2hub systemd user service')
    ap.add_argument('--hub-cmd', help='command that starts the hub; {port} is replaced (for testing)')
    ap.add_argument('--timeout', type=float, default=45.0, help='seconds to wait for the hub to start')
    ap.add_argument('--check', action='store_true', help='start/attach hub, print status JSON, exit')
    ap.add_argument('--system-frame', action='store_true',
                    help="use the desktop's normal title bar instead of G2 Hub's own")
    args = ap.parse_args(argv)
    args.url = (args.url or f'http://127.0.0.1:{args.port}').rstrip('/')
    if urllib.parse.urlsplit(args.url).hostname == 'localhost':      # hub accepts both; be explicit
        args.url = args.url.replace('://localhost', '://127.0.0.1', 1)

    if not args.browser and not args.check:
        _reexec_with_venv(argv)

    app = DesktopApp(args)
    if args.check:
        return run_check(app)

    inst = SingleInstance(app.port)
    token = os.environ.get('XDG_ACTIVATION_TOKEN') or os.environ.get('DESKTOP_STARTUP_ID') or ''
    if inst.signal_existing(('show ' + token).strip().encode()):
        log('G2 Hub is already running; asked it to show its window')
        return 0
    for var in ('XDG_ACTIVATION_TOKEN', 'DESKTOP_STARTUP_ID'):   # don't leak into the hub child
        os.environ.pop(var, None)

    # Identity for the desktop shell, set before GTK is initialised (tray.py imports Gtk):
    # Wayland app_id = prgname, X11 WM_CLASS = (prgname, program class). Both are "g2hub", which
    # matches g2hub.desktop (StartupWMClass=g2hub), so the dock groups the window and shows its icon.
    try:
        import gi
        gi.require_version('Gtk', '3.0')
        gi.require_version('Gdk', '3.0')
        from gi.repository import GLib
        GLib.set_prgname(APP_ID)
        GLib.set_application_name(APP_NAME)
        app.GLib = GLib
    except (ImportError, ValueError):
        GLib = None
    try:
        from gi.repository import Gdk, Gtk  # noqa: F401  (initialises GTK, which resets the class)
        Gdk.set_program_class(APP_ID)
    except Exception:  # noqa: BLE001
        pass

    from tray import tray_supported
    tray_ok, why = (False, 'disabled') if args.no_tray else tray_supported()
    if not tray_ok and not args.no_tray:
        log(f'no tray icon: {why}')
    use_webview, backend = (False, 'browser') if args.browser else webview_available()
    if not use_webview and not args.browser:
        log(f'native window unavailable ({backend}); using the web browser')

    app.tray_ok = tray_ok

    def on_instance_message(msg):
        cmd, _, tok = msg.partition(' ')
        if cmd == 'show':
            app.on_gtk(app.open, tok.strip() or None)
    inst.listen(on_instance_message)
    if GLib is not None:
        app.watch_resume()

    def on_signal(*_):
        app.quit()
        return False

    if GLib is not None:
        try:
            from gi.repository import GLibUnix
            sig_add = GLibUnix.signal_add
        except ImportError:
            sig_add = GLib.unix_signal_add
        for sig in (signal.SIGINT, signal.SIGTERM):
            sig_add(GLib.PRIORITY_DEFAULT, sig, on_signal)
    else:
        signal.signal(signal.SIGTERM, lambda *_: app.quit())

    try:
        if use_webview:
            _run_webview(app, backend, tray_ok)
        else:
            _run_browser(app, tray_ok)
    except KeyboardInterrupt:
        pass
    finally:
        app._stopped.set()
        if app.bridge:
            app.bridge.stop()
        inst.close()
        app.hub.stop()
    return 0


def _is_x11():
    try:
        from gi.repository import Gdk
        return 'X11' in type(Gdk.Display.get_default()).__name__
    except Exception:  # noqa: BLE001
        return False


def initial_geometry(saved):
    """Window size/position for create_window from the saved geometry, kept on screen."""
    width, height = 1280, 860
    x = y = None
    maximized = False
    if isinstance(saved, dict):
        try:
            width = int(saved.get('width') or width)
            height = int(saved.get('height') or height)
            maximized = bool(saved.get('maximized'))
            if saved.get('x') is not None and saved.get('y') is not None:
                x, y = int(saved['x']), int(saved['y'])
        except (TypeError, ValueError):
            pass
    area = None
    try:
        from gi.repository import Gdk
        disp = Gdk.Display.get_default()
        mon = disp.get_primary_monitor() or disp.get_monitor(0)
        area = mon.get_workarea()
    except Exception:  # noqa: BLE001
        pass
    if area is not None and area.width > 0:
        width = max(MIN_SIZE[0], min(width, area.width))
        height = max(MIN_SIZE[1], min(height, area.height))
        if x is not None and not _is_x11():
            x = y = None
        if x is not None and not (area.x - width + 80 <= x <= area.x + area.width - 80
                                  and area.y <= y <= area.y + area.height - 40):
            x = y = None                          # saved position is off-screen now
    else:
        width, height = max(MIN_SIZE[0], width), max(MIN_SIZE[1], height)
    return dict(width=width, height=height, x=x, y=y, maximized=maximized)


MIN_SIZE = (900, 600)


def _run_webview(app, backend, tray_ok):
    import webview
    try:
        app.hub.start()                            # spawn from the main thread; bootstrap() waits
    except RuntimeError as e:
        app.start_error = e
    hidden = bool(app.args.minimized and tray_ok)
    frameless = backend == 'gtk' and not app.args.system_frame
    geo = initial_geometry(app.cfg['window'])
    chrome = None
    if frameless:
        from chrome import WindowChrome
        chrome = WindowChrome(None, dict(hide=app.hide_window, quit=app.quit, open_external=_open_browser,
                                         geometry_changed=app.geometry_changed), log=log)
    win = webview.create_window(APP_NAME, html=splash_html('Starting G2 Hub...',
                                                           'Starting the hub server and connecting to your glasses.'),
                                width=geo['width'], height=geo['height'], x=geo['x'], y=geo['y'],
                                maximized=geo['maximized'], min_size=MIN_SIZE, hidden=hidden,
                                background_color=WINDOW_BG, text_select=True, zoomable=False,
                                frameless=frameless, easy_drag=False,
                                js_api=chrome.api if chrome else None)
    app.window = win
    if chrome is not None:
        chrome.window = win

        def attach():                              # GTK thread, before the first page loads
            try:
                chrome.attach()
                app.chrome = chrome
            except Exception as e:  # noqa: BLE001
                log(f'custom title bar unavailable ({e}); falling back to the system title bar')
                try:
                    win.native.set_decorated(True)
                except Exception:  # noqa: BLE001
                    pass
        win.events.before_show += attach

    def on_closing():
        if app.quitting:
            return True
        if app.chrome is not None:
            app.save_geometry()
        if tray_ok and app.tray is not None and app.cfg['close_to_tray']:
            win.hide()
            return False                           # cancel the close; keep running in the tray
        app.quitting = True                        # window closes -> webview.start() returns
        app._stopped.set()
        app._poke.set()
        return True

    win.events.closing += on_closing
    storage = state_dir() / 'webview'
    storage.mkdir(parents=True, exist_ok=True)
    webview.start(app.bootstrap, (tray_ok,), gui=backend, private_mode=False, storage_path=str(storage),
                  icon=str(ICON_PNG if ICON_PNG.exists() else ICON))


def _run_browser(app, tray_ok):
    try:
        app.hub.ensure(timeout=app.args.timeout)
    except RuntimeError as e:
        desktop_notify('G2 Hub could not start', str(e))
        log(f'hub failed to start: {e}\n{app.hub.log_tail()}')
        return
    if not app.args.minimized:
        _open_browser(app.url)
    if tray_ok and app.GLib is not None:
        from gi.repository import Gtk
        app.start_services(True)
        Gtk.main()
    else:
        log(f'G2 Hub is running at {app.url} - press Ctrl+C to stop')
        app.start_services(False)
        app._stopped.wait()


if __name__ == '__main__':
    sys.exit(main())
