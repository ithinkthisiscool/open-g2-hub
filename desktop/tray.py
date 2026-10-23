"""System-tray icon for G2 Hub (StatusNotifierItem via libayatana-appindicator / libappindicator).

Works on KDE Plasma out of the box and on GNOME when the "AppIndicator and KStatusNotifierItem
Support" extension is enabled (Ubuntu ships it on by default). All methods must run on the GTK
main thread; the launcher marshals calls with GLib.idle_add.
"""
from pathlib import Path

ICON_DIR = Path(__file__).resolve().parent / 'icons'
ICON_ON = 'g2hub-tray-connected'
ICON_OFF = 'g2hub-tray-disconnected'

_GI_ERR = None
try:
    import gi
    gi.require_version('Gtk', '3.0')
    from gi.repository import Gio, GLib, Gtk  # noqa: F401
    AppIndicator = None
    for _name in ('AyatanaAppIndicator3', 'AppIndicator3'):
        try:
            gi.require_version(_name, '0.1')
            AppIndicator = getattr(__import__('gi.repository', fromlist=[_name]), _name)
            break
        except (ValueError, ImportError, AttributeError):
            continue
except (ImportError, ValueError) as e:   # no PyGObject / GTK 3
    gi = Gtk = GLib = Gio = AppIndicator = None
    _GI_ERR = e


def tray_host_present():
    """True if some panel is listening for tray icons (org.kde.StatusNotifierWatcher)."""
    if Gio is None:
        return False
    try:
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        res = bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus',
                            'NameHasOwner', GLib.Variant('(s)', ('org.kde.StatusNotifierWatcher',)),
                            GLib.VariantType('(b)'), Gio.DBusCallFlags.NONE, 1000, None)
        return bool(res.unpack()[0])
    except Exception:  # noqa: BLE001
        return False


def tray_supported():
    """(ok, reason)."""
    if Gtk is None:
        return False, f'PyGObject/GTK 3 not importable ({_GI_ERR})'
    if AppIndicator is None:
        return False, 'libayatana-appindicator (gir1.2-ayatanaappindicator3-0.1) not installed'
    if not tray_host_present():
        return False, ('no tray host on the desktop (GNOME: enable the "AppIndicator and '
                       'KStatusNotifierItem Support" extension)')
    return True, ''


def describe(state):
    """Human status line + short panel label from a poll snapshot."""
    if not state.get('reachable'):
        return 'Hub not running', ''
    name = state.get('active_name') or 'Glasses'
    if not state.get('connected'):
        link = state.get('link')
        if link == 'disabled':
            return 'Hub runs without Bluetooth (G2HUB_NO_BLE)', ''
        if link == 'paused':
            why = 'Bluetooth adapter off' if 'adapter' in (state.get('paused') or []) else 'paused'
            return f'{name}: {why}', ''
        if state.get('reconnecting'):
            return f'{name}: reconnecting...', ''
        return f'{name}: not connected', ''
    parts = [f'{name}: connected']
    label = ''
    bat = state.get('battery')
    if bat is not None:
        label = f'{bat}%'
        parts.append(f'battery {bat}%' + (' (charging)' if state.get('charging') else ''))
    if state.get('case_battery') is not None:
        parts.append(f'case {state["case_battery"]}%')
    if state.get('worn') is not None:
        parts.append('worn' if state['worn'] else 'not worn')
    return ' - '.join(parts[:1]) + ((' | ' + ', '.join(parts[1:])) if parts[1:] else ''), label


class Tray:
    """callbacks: open(), scan(), select(dev_id), set_forwarding(bool), quit(); optional
    quick_send() and quick_send_preset() add the quick-send items when present."""

    def __init__(self, callbacks, forwarding=False):
        self.cb = callbacks
        self._devices_sig = None
        self._updating = False
        ind = AppIndicator.Indicator.new('g2hub', ICON_OFF, AppIndicator.IndicatorCategory.HARDWARE)
        ind.set_icon_theme_path(str(ICON_DIR))
        ind.set_status(AppIndicator.IndicatorStatus.ACTIVE)
        ind.set_title('G2 Hub')
        self.ind = ind

        menu = Gtk.Menu()
        self.m_status = Gtk.MenuItem(label='Starting...')
        self.m_status.set_sensitive(False)
        menu.append(self.m_status)
        menu.append(Gtk.SeparatorMenuItem())

        m_open = Gtk.MenuItem(label='Open G2 Hub')
        m_open.connect('activate', lambda *_: self.cb['open']())
        menu.append(m_open)

        self.m_scan = Gtk.MenuItem(label='Scan for glasses')
        self.m_scan.connect('activate', lambda *_: self.cb['scan']())
        menu.append(self.m_scan)

        self.m_switch = Gtk.MenuItem(label='Switch glasses')
        self.m_switch.set_submenu(Gtk.Menu())
        menu.append(self.m_switch)

        # Quick send: flash a short note on the glasses without opening the web UI. Always present
        # (the dependable path); the preset item appears only when a preset note is configured.
        if 'quick_send' in self.cb:
            menu.append(Gtk.SeparatorMenuItem())
            m_qs = Gtk.MenuItem(label='Quick send…')
            m_qs.connect('activate', lambda *_: self.cb['quick_send']())
            menu.append(m_qs)
            if self.cb.get('quick_send_preset'):
                m_qsp = Gtk.MenuItem(label='Send preset note')
                m_qsp.connect('activate', lambda *_: self.cb['quick_send_preset']())
                menu.append(m_qsp)

        menu.append(Gtk.SeparatorMenuItem())
        self.m_fwd = Gtk.CheckMenuItem(label='Forward desktop notifications')
        self.m_fwd.set_active(bool(forwarding))
        self.m_fwd.connect('toggled', self._on_fwd)
        menu.append(self.m_fwd)

        menu.append(Gtk.SeparatorMenuItem())
        m_quit = Gtk.MenuItem(label='Quit G2 Hub')
        m_quit.connect('activate', lambda *_: self.cb['quit']())
        menu.append(m_quit)

        menu.show_all()
        self.menu = menu
        ind.set_menu(menu)
        ind.set_secondary_activate_target(m_open)   # middle-click opens the window

    def _on_fwd(self, item):
        if not self._updating:
            self.cb['set_forwarding'](item.get_active())

    def set_forwarding(self, on):
        self._updating = True
        self.m_fwd.set_active(bool(on))
        self._updating = False

    def set_scanning(self, busy):
        self.m_scan.set_sensitive(not busy)
        self.m_scan.set_label('Scanning...' if busy else 'Scan for glasses')

    def update(self, state):
        line, label = describe(state)
        self.m_status.set_label(line)
        connected = bool(state.get('reachable') and state.get('connected'))
        self.ind.set_icon_full(ICON_ON if connected else ICON_OFF, line)
        self.ind.set_label(label, '100%')
        self.ind.set_title(f'G2 Hub - {line}')
        self._update_devices(state.get('devices') or [], state.get('active'))
        return False    # one-shot when used with GLib.idle_add

    def _update_devices(self, devices, active):
        sig = (tuple((d.get('id'), d.get('name'), d.get('pair_id')) for d in devices), active)
        if sig == self._devices_sig:
            return
        self._devices_sig = sig
        sub = Gtk.Menu()
        group = None
        for d in devices:
            label = d.get('name') or d.get('pair_id') or f'Glasses {d.get("id")}'
            if d.get('name') and d.get('pair_id') and d['pair_id'] not in label:
                label += f'  ({d["pair_id"]})'
            item = Gtk.RadioMenuItem.new_with_label_from_widget(group, label)
            group = group or item
            item.set_active(d.get('id') == active)
            item.connect('toggled', self._on_select, d.get('id'))
            sub.append(item)
        if not devices:
            none = Gtk.MenuItem(label='No saved glasses - open G2 Hub to add some')
            none.set_sensitive(False)
            sub.append(none)
        sub.show_all()
        self.m_switch.set_submenu(sub)
        self.m_switch.set_sensitive(len(devices) > 1 or not devices)

    def _on_select(self, item, dev_id):
        if item.get_active() and self._devices_sig and dev_id != self._devices_sig[1]:
            self.cb['select'](dev_id)
