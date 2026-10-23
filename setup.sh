#!/usr/bin/env bash
# One-step installer for G2 Hub (Linux). Creates a Python virtual environment in this folder and
# installs the g2 library (../g2) and the hub into it. Safe to run again.
#
#   ./setup.sh              set up (or repair) .venv; an existing working .venv is left alone
#   ./setup.sh --force      delete and rebuild .venv from scratch
#   ./setup.sh --venv DIR   use DIR instead of ./.venv (then run with G2HUB_VENV=DIR ./run.sh)
#
# Needs network access (pip). Never uses sudo and never touches the Bluetooth adapter.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
VENV="${G2HUB_VENV:-$HERE/.venv}"
FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --venv) shift; [ $# -gt 0 ] || { echo "--venv needs a folder" >&2; exit 2; }; VENV="$(realpath -m "$1")" ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

ok()   { printf '  [ok]   %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; WARNED=1; }
die()  { printf '  [FAIL] %s\n' "$*" >&2; exit 1; }
WARNED=0

echo "G2 Hub setup  (version $(python3 -c 'import sys; sys.path.insert(0,"."); import hub.version as v; print(v.__version__)' 2>/dev/null || echo '?'))"
echo
echo "Checking your computer..."

# --- required -------------------------------------------------------------------------------
SYSPY="${PYTHON:-python3}"
command -v "$SYSPY" >/dev/null || die "python3 not found. Install Python 3.11 or newer (Ubuntu/Debian: sudo apt install python3 python3-venv)."
"$SYSPY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' \
  || die "Python 3.11 or newer is required, found $("$SYSPY" -c 'import platform; print(platform.python_version())'). Install a newer python3 (or run: PYTHON=python3.12 ./setup.sh)."
ok "Python $("$SYSPY" -c 'import platform; print(platform.python_version())')"

[ -f "$HERE/../g2/pyproject.toml" ] \
  || die "the g2 library folder is missing: expected $(realpath -m "$HERE/../g2"). Keep g2-hub and g2 side by side (both inside the eveng2 folder)."
ok "g2 library found at $(realpath "$HERE/../g2")"

# --- Bluetooth (needed to talk to the glasses; warn only, so you can still install) ----------
if command -v bluetoothctl >/dev/null; then
  ok "BlueZ (bluetoothctl) is installed"
  if bluetoothctl list 2>/dev/null | grep -q '^Controller'; then
    ok "Bluetooth adapter found"
  else
    warn "no Bluetooth adapter detected. Plug one in or turn Bluetooth on (rfkill unblock bluetooth; bluetoothctl power on). The hub will wait for one."
  fi
else
  warn "BlueZ is not installed. Ubuntu/Debian: sudo apt install bluez   (Fedora: sudo dnf install bluez)"
fi

# --- desktop app only -----------------------------------------------------------------------
if "$SYSPY" -c 'import gi; gi.require_version("Gtk","3.0"); gi.require_version("WebKit2","4.1"); from gi.repository import Gtk, WebKit2' 2>/dev/null; then
  ok "GTK + WebKit found (desktop app will work)"
else
  warn "GTK/WebKit for Python not found. Only the desktop window needs it; the web UI in your browser works without. Ubuntu/Debian: sudo apt install python3-gi gir1.2-webkit2-4.1"
fi

# --- virtual environment --------------------------------------------------------------------
echo
echo "Setting up the environment in $VENV ..."
PYV="$VENV/bin/python"
healthy() { [ -x "$PYV" ] && "$PYV" -c "import g2, bleak, aiohttp, dbus_fast" 2>/dev/null; }

if [ "$FORCE" = 1 ] && [ -e "$VENV" ]; then
  [ "$VENV" != "/" ] && [ "$VENV" != "$HOME" ] && [ "$VENV" != "$HERE" ] || die "refusing to delete $VENV"
  echo "  --force: removing $VENV"
  rm -rf "$VENV"
fi

if healthy; then
  ok "existing environment already works - leaving it as it is (use --force to rebuild)"
else
  if [ ! -x "$PYV" ]; then
    if "$SYSPY" -m venv "$VENV" 2>/dev/null; then
      ok "created virtual environment"
    else
      rm -rf "$VENV"
      # Debian/Ubuntu without python3-venv/ensurepip: make it pip-less and let system pip fill it.
      "$SYSPY" -m venv --system-site-packages --without-pip "$VENV" \
        || die "could not create a virtual environment. Ubuntu/Debian: sudo apt install python3-venv"
      ok "created virtual environment (without its own pip)"
    fi
  else
    ok "reusing existing environment, installing what is missing"
  fi
  if "$PYV" -m pip --version >/dev/null 2>&1; then
    PIP=("$PYV" -m pip)
  else
    PIP=("$SYSPY" -m pip --python "$PYV")
    "$SYSPY" -m pip --version >/dev/null 2>&1 || die "pip is not available. Ubuntu/Debian: sudo apt install python3-pip"
  fi
  echo "  installing the g2 library (editable, from ../g2) ..."
  "${PIP[@]}" install -q -e "$HERE/../g2" || die "could not install ../g2 (is the network up?)"
  echo "  installing the hub and its dependencies ..."
  "${PIP[@]}" install -q -e "$HERE" || die "could not install the hub dependencies (is the network up?)"
fi

# --- verify ---------------------------------------------------------------------------------
echo
"$PYV" -c "import g2, hub.version as v; print('  [ok]   g2 library + hub', v.__version__, 'import correctly')" \
  || die "installed, but 'import g2' still fails. Re-run with --force."

echo
if [ "$WARNED" = 1 ]; then echo "Setup finished, with warnings above (the hub can start, but fix them to reach the glasses)."
else echo "Setup finished. Everything looks good."; fi
cat <<NEXT

Next steps:
  1. Take the glasses out of the case and close the Even phone app (only one thing can hold them).
  2. Start the hub:      ./run.sh$( [ "$VENV" = "$HERE/.venv" ] || printf '   (with G2HUB_VENV=%s)' "$VENV" )
  3. Open:               http://localhost:8766   then Scan and Add your glasses.
  Optional desktop app / menu entry:   desktop/install.sh
  Plain-language guide:                docs/getting-started.md
NEXT
