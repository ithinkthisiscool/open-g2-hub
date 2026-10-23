"""The G2 hub: a local web app that replaces the official Even phone app for the features we have
reverse-engineered. It keeps one BLE session to the glasses and drives them through the g2
library (g2.dashboard, g2.menu, g2.quicklist, g2.file_service, g2.even_ai), with a browser UI:
General tab (live-synced calendar, tasks, menu, news, Even AI assistant), Testing tab (manual and
experimental pushes), Log tab (every frame and event, streamed over a WebSocket).

The session connects with launch_app=True, skip_page=True: the EvenHub heartbeat runs (SID 0x01
writes are only accepted while it does) but no EvenHub page is drawn, so the native dashboard stays
visible. Incoming frames are observed through session.on_raw_frame (read-only).

Usage (from the repo root):  .venv/bin/python hub/native_hub_gui.py [port, default 8766]
Then open http://localhost:<port>. Files: ~/.local/share/g2hub (hub.db), ~/.config/g2hub (token,
optional .env), ~/.local/state/g2hub/hub.jsonl — see hub/paths.py. API keys (Even AI) go in
~/.config/g2hub/.env or hub/.env — see hub/.env.example.

This file is only the entry point; the hub lives in the `hub` package:
    app.py          startup, web server, shutdown          connection.py   BLE link lifecycle
    state.py        shared context / store / supervisor    frames.py       incoming-frame dispatch
    routes/*.py     HTTP handlers + feature services       web/page.py     the UI (HTML/CSS/JS)
    power.py        suspend / lid / adapter power           supervisor.py   task ownership
    paths.py        XDG dirs + migration                   auth.py         local API token
    logs.py         rotating JSON log                      events.py       Live log + WebSocket
"""
import os
import sys

_HUB_DIR = os.path.dirname(os.path.abspath(__file__))
_PY_ROOT = os.path.dirname(_HUB_DIR)
# Import everything as the `hub` package (python/ on sys.path), never as top-level modules from
# the hub directory, so each module is loaded exactly once.
sys.path[:] = [p for p in sys.path if os.path.abspath(p or '.') != _HUB_DIR]
sys.path.insert(0, _PY_ROOT)

from hub.app import run  # noqa: E402

if __name__ == '__main__':
    run()
