"""Desktop-app settings, stored in ~/.config/g2hub/desktop.json (XDG_CONFIG_HOME respected)."""
import json
import os
import threading
from pathlib import Path

APP_ID = 'g2hub'
APP_NAME = 'G2 Hub'

DEFAULTS = {
    # Window: closing it hides to the tray (only when a tray is actually available).
    'close_to_tray': True,
    # Desktop notifications -> glasses bridge. OFF by default (privacy).
    'forward_notifications': False,
    # Only notifications whose app name matches one of these (case-insensitive) are forwarded.
    # ["*"] means every app. Empty list means nothing is forwarded.
    'allow_apps': [],
    # 'full' = title + body, 'title' = title only, 'app' = just "New notification from <app>".
    'forward_content': 'full',
    'max_per_minute': 6,          # hard cap on forwarded notifications per rolling minute
    'min_interval_s': 5,          # minimum gap between two forwarded notifications
    'dedupe_window_s': 60,        # identical app+title+body within this window is dropped
    # Last window geometry, restored on the next start: {width, height, x, y, maximized}.
    # x/y are only known (and only restored) on X11; Wayland does not let apps place windows.
    'window': {},
}


def config_dir():
    return Path(os.environ.get('XDG_CONFIG_HOME') or Path.home() / '.config') / APP_ID


def state_dir():
    return Path(os.environ.get('XDG_STATE_HOME') or Path.home() / '.local' / 'state') / APP_ID


class Config:
    def __init__(self, path=None):
        self.path = Path(path) if path else config_dir() / 'desktop.json'
        self._lock = threading.Lock()
        self.data = dict(DEFAULTS)
        self.load()

    def load(self):
        try:
            with open(self.path) as f:
                user = json.load(f)
            if isinstance(user, dict):
                self.data.update({k: v for k, v in user.items() if k in DEFAULTS})
        except FileNotFoundError:
            pass
        except (OSError, ValueError) as e:
            print(f'[desktop] ignoring unreadable config {self.path}: {e}', flush=True)
        return self.data

    def save(self):
        with self._lock:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix('.tmp')
            with open(tmp, 'w') as f:
                json.dump(self.data, f, indent=2)
                f.write('\n')
            os.replace(tmp, self.path)

    def __getitem__(self, k):
        return self.data.get(k, DEFAULTS.get(k))

    def set(self, k, v):
        self.data[k] = v
        self.save()
