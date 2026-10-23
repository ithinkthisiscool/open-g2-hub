#!/usr/bin/env bash
# Install the G2 Hub desktop integration for the CURRENT USER only (never touches system paths).
#
#   ./install.sh               app menu entry + icon + `g2hub` command
#   ./install.sh --autostart   ...and start G2 Hub (in the tray) when you log in
#   ./install.sh --service     ...and run the hub server as a systemd *user* service
#                              (always on, restarts on failure; the window attaches to it)
#
# Safe to run again (it just rewrites the same files). Undo with ./uninstall.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_ROOT="$(dirname "$HERE")"
PYTHON="$PY_ROOT/${G2HUB_VENV:-.venv}/bin/python"
case "${G2HUB_VENV:-}" in /*) PYTHON="$G2HUB_VENV/bin/python" ;; esac
LAUNCHER="$HERE/g2hub_desktop.py"
HUB="$PY_ROOT/hub/native_hub_gui.py"

DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}"
BIN="$HOME/.local/bin"
APPS="$DATA/applications"
ICONS="$DATA/icons/hicolor"
UNITS="$CONF/systemd/user"
AUTOSTART="$CONF/autostart"

WANT_SERVICE=0; WANT_AUTOSTART=0
for a in "$@"; do
  case "$a" in
    --service) WANT_SERVICE=1 ;;
    --autostart) WANT_AUTOSTART=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $a (try --help)" >&2; exit 2 ;;
  esac
done

say() { printf '  %s\n' "$*"; }
# Quote a path for a .desktop Exec= line (spec: double quotes, escape " ` $ \).
dq() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//\`/\\\`}"; s="${s//\$/\\\$}"; printf '"%s"' "$s"; }

# The launchers must point at an environment that can actually run the hub.
if [ ! -x "$PYTHON" ] || ! "$PYTHON" -c "import g2, bleak, aiohttp" 2>/dev/null; then
  echo "G2 Hub isn't set up yet: the g2 library isn't installed in $PYTHON" >&2
  echo "Run ./setup.sh in $PY_ROOT first, then run this installer again." >&2
  exit 1
fi

echo "Installing G2 Hub for $USER"
[ -f "$LAUNCHER" ] || { echo "missing $LAUNCHER" >&2; exit 1; }
mkdir -p "$APPS" "$ICONS/scalable/apps" "$BIN"

# 1. Icons: scalable app icon + tray icons (so the tray can also find them by name), and
#    pre-rendered PNGs per size (crisper at 16-48 px than the scaled SVG; docks use them).
for f in g2hub g2hub-tray-connected g2hub-tray-disconnected; do
  install -m 644 "$HERE/icons/$f.svg" "$ICONS/scalable/apps/$f.svg"
done
for sz in 16 24 32 48 64 128 256 512; do
  png="$HERE/icons/png/g2hub-$sz.png"
  [ -f "$png" ] || continue
  mkdir -p "$ICONS/${sz}x${sz}/apps"
  install -m 644 "$png" "$ICONS/${sz}x${sz}/apps/g2hub.png"
done
say "icons      -> $ICONS/{scalable,16x16..512x512}/apps/"

# 2. `g2hub` command
cat > "$BIN/g2hub" <<SH
#!/bin/sh
# G2 Hub desktop app (installed by $HERE/install.sh)
exec "$PYTHON" "$LAUNCHER" "\$@"
SH
chmod 755 "$BIN/g2hub"
say "command    -> $BIN/g2hub"

# 3. App-menu entry
EXEC="$(dq "$PYTHON") $(dq "$LAUNCHER")"
cat > "$APPS/g2hub.desktop" <<DESK
[Desktop Entry]
Type=Application
Version=1.5
Name=G2 Hub
GenericName=Smart Glasses Hub
Comment=Control your Even Realities G2 glasses
Exec=$EXEC
Icon=g2hub
Terminal=false
Categories=Utility;
Keywords=glasses;even;realities;g2;bluetooth;hud;
StartupNotify=true
StartupWMClass=g2hub
SingleMainWindow=true
Actions=browser;

[Desktop Action browser]
Name=Open in Web Browser
Exec=$EXEC --browser
DESK
say "menu entry -> $APPS/g2hub.desktop"

# 4. Autostart (tray only, no window) - optional
if [ "$WANT_AUTOSTART" = 1 ]; then
  mkdir -p "$AUTOSTART"
  cat > "$AUTOSTART/g2hub.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=G2 Hub
Comment=Start G2 Hub in the system tray
Exec=$EXEC --minimized
Icon=g2hub
Terminal=false
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=5
X-KDE-autostart-after=panel
DESK
  say "autostart  -> $AUTOSTART/g2hub.desktop"
fi

# 5. systemd user service (hub server only) - optional
if [ "$WANT_SERVICE" = 1 ]; then
  mkdir -p "$UNITS"
  cat > "$UNITS/g2hub.service" <<UNIT
[Unit]
Description=G2 Hub server (Even Realities G2 glasses, http://localhost:8766)
Documentation=file://$PY_ROOT/docs/desktop.md
After=bluetooth.target network-online.target

[Service]
Type=simple
WorkingDirectory=$PY_ROOT
ExecStart="$PYTHON" "$HUB" 8766
Environment=PYTHONUNBUFFERED=1
# The hub reads its API keys itself from ~/.config/g2hub/.env (KEY=value lines, see docs/hub.md);
# loading the same file here also makes them plain environment variables.
EnvironmentFile=-%h/.config/g2hub/.env
KillSignal=SIGINT
TimeoutStopSec=15
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
  say "service    -> $UNITS/g2hub.service"
  if [ -z "${G2HUB_SKIP_SYSTEMCTL:-}" ] && command -v systemctl >/dev/null; then
    systemctl --user daemon-reload
    systemctl --user enable g2hub.service >/dev/null 2>&1 && say "service enabled (starts at login)"
    if "$PYTHON" - <<'PY'
import socket, sys
s = socket.socket(); s.settimeout(1)
sys.exit(0 if s.connect_ex(('127.0.0.1', 8766)) != 0 else 1)   # 0 = port free
PY
    then
      systemctl --user start g2hub.service && say "service started"
    else
      say "a hub is already running on port 8766 - stop it, then: systemctl --user start g2hub.service"
    fi
  fi
fi

# 6. Refresh desktop caches (user dirs only; all optional)
command -v update-desktop-database >/dev/null && update-desktop-database -q "$APPS" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null && [ -f "$ICONS/index.theme" ] && gtk-update-icon-cache -q -t "$ICONS" 2>/dev/null || true
touch "$ICONS" 2>/dev/null || true

echo "Done. Open \"G2 Hub\" from your applications menu, or run: g2hub"
case ":$PATH:" in *":$BIN:"*) ;; *) echo "(note: $BIN is not on your PATH; the menu entry works anyway)";; esac
