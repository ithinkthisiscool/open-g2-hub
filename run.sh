#!/usr/bin/env bash
# Start the G2 hub (web UI on http://localhost:8766, or the port given as $1).
# Uses the virtual environment made by ./setup.sh (.venv/ here, or $G2HUB_VENV). See docs/hub.md.
#
#   ./run.sh              # connect to the glasses, UI on :8766
#   ./run.sh 8770         # another port
#   ./run.sh --version    # print the hub version and exit
#   G2HUB_NO_BLE=1 ./run.sh 8770   # web UI only, no Bluetooth (safe next to a running hub)
set -euo pipefail
cd "$(dirname "$0")"
VENV="${G2HUB_VENV:-.venv}"
PY="$VENV/bin/python"

if [ "${1:-}" = "--version" ] || [ "${1:-}" = "-V" ]; then
  # hub/version.py is stdlib-only, so any python3 will do if there is no venv yet.
  [ -x "$PY" ] || PY="$(command -v python3 || true)"
  [ -n "$PY" ] || { echo "python3 not found" >&2; exit 1; }
  exec "$PY" -c "import hub.version as v; print(v.__version__)"
fi
case "${1:-}" in -h|--help) sed -n '2,9p' "$0"; exit 0 ;; esac

if [ ! -x "$PY" ]; then
  echo "G2 Hub is not set up yet (no virtual environment at $VENV)." >&2
  echo "Run ./setup.sh once, then ./run.sh again." >&2
  exit 1
fi
if ! "$PY" -c "import g2, bleak, aiohttp" 2>/dev/null; then
  echo "The g2 library (or bleak/aiohttp) isn't installed in this environment ($VENV)." >&2
  echo "Run ./setup.sh to install it, then ./run.sh again." >&2
  exit 1
fi
exec "$PY" hub/native_hub_gui.py "${1:-8766}"
