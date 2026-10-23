#!/usr/bin/env bash
# Remove everything install.sh added for this user. Safe to run more than once.
# --purge also removes the desktop app's own settings and state (desktop.json, window storage, the
# hub.log capture). The hub's files are always kept: ~/.config/g2hub/{.env,token,hub.json} (API keys,
# API token, hub settings) and ~/.local/share/g2hub (your glasses, widgets, Even AI history).
set -euo pipefail
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}"
PURGE=0; [ "${1:-}" = "--purge" ] && PURGE=1

say() { printf '  %s\n' "$*"; }
rm_f() { if [ -e "$1" ] || [ -L "$1" ]; then rm -f -- "$1"; say "removed $1"; fi; }

echo "Uninstalling G2 Hub desktop integration for $USER"
UNIT="$CONF/systemd/user/g2hub.service"
if [ -e "$UNIT" ]; then
  if [ -z "${G2HUB_SKIP_SYSTEMCTL:-}" ] && command -v systemctl >/dev/null; then
    systemctl --user disable --now g2hub.service >/dev/null 2>&1 || true
    say "service stopped and disabled"
  fi
  rm_f "$UNIT"
  [ -z "${G2HUB_SKIP_SYSTEMCTL:-}" ] && command -v systemctl >/dev/null && systemctl --user daemon-reload || true
fi
rm_f "$CONF/autostart/g2hub.desktop"
rm_f "$DATA/applications/g2hub.desktop"
for f in g2hub g2hub-tray-connected g2hub-tray-disconnected; do rm_f "$DATA/icons/hicolor/scalable/apps/$f.svg"; done
for sz in 16 24 32 48 64 128 256 512; do rm_f "$DATA/icons/hicolor/${sz}x${sz}/apps/g2hub.png"; done
if [ -f "$HOME/.local/bin/g2hub" ] && grep -q 'G2 Hub desktop app' "$HOME/.local/bin/g2hub"; then rm_f "$HOME/.local/bin/g2hub"; fi
command -v update-desktop-database >/dev/null && update-desktop-database -q "$DATA/applications" 2>/dev/null || true
if [ "$PURGE" = 1 ]; then
  rm_f "$CONF/g2hub/desktop.json"
  rm_f "$CONF/g2hub/desktop.tmp"
  if [ -d "$STATE/g2hub/webview" ]; then rm -rf -- "$STATE/g2hub/webview"; say "removed $STATE/g2hub/webview"; fi
  for f in "$STATE/g2hub/hub.log" "$STATE/g2hub/hub.log.1"; do rm_f "$f"; done
  rmdir "$CONF/g2hub" "$STATE/g2hub" 2>/dev/null || true
  say "kept the hub's own files (~/.config/g2hub: .env, token, hub.json; ~/.local/share/g2hub; hub.jsonl logs)"
fi
echo "Done."
