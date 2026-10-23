"""Where the hub keeps its files (XDG base directories), and the one-time move from the old layout.

    data    ~/.local/share/g2hub   hub.db (per-pair config + Even AI log), hn_cache.json
    config  ~/.config/g2hub        token (local API token, 0600), optional .env with API keys
    state   ~/.local/state/g2hub   hub.jsonl (+ rotated hub.jsonl.1 ... .5); hub.log there is the
                                   desktop app's capture of the hub's stdout/stderr, not ours

Overrides (checked first): G2HUB_DATA_DIR, G2HUB_CONFIG_DIR, G2HUB_STATE_DIR. Otherwise the
standard XDG_DATA_HOME / XDG_CONFIG_HOME / XDG_STATE_HOME variables are respected.

Before this layout existed, everything lived next to the source in hub/. On the first run
with the default data dir, migrate_legacy() copies hub.db (with SQLite's online backup, so it is
consistent) and hn_cache.json into the data dir, renames the originals to *.migrated, and leaves a
marker so it never runs again. To keep using hub/ as before, start the hub with
G2HUB_DATA_DIR=<path to hub>; nothing is migrated then.

Stdlib only: the desktop app may import this module (via hub.auth) without the hub's deps.
"""
import json
import os
import shutil
import sqlite3
import time
from pathlib import Path

APP_ID = 'g2hub'
LEGACY_DIR = Path(__file__).resolve().parent          # hub (the pre-XDG location)
MIGRATION_MARKER = '.migrated_from_legacy.json'
DB_NAME = 'hub.db'
NEWS_CACHE_NAME = 'hn_cache.json'
LOG_NAME = 'hub.jsonl'       # hub.log in the same dir is the desktop app's capture of stdout


def _xdg(env_override, xdg_var, default_rel):
    val = os.environ.get(env_override)
    if val:
        return Path(val).expanduser()
    base = os.environ.get(xdg_var)
    return (Path(base).expanduser() if base else Path.home() / default_rel) / APP_ID


def data_dir():
    return _xdg('G2HUB_DATA_DIR', 'XDG_DATA_HOME', '.local/share')


def config_dir():
    return _xdg('G2HUB_CONFIG_DIR', 'XDG_CONFIG_HOME', '.config')


def state_dir():
    return _xdg('G2HUB_STATE_DIR', 'XDG_STATE_HOME', '.local/state')


def db_path():
    return data_dir() / DB_NAME


def news_cache_path():
    return data_dir() / NEWS_CACHE_NAME


def log_path():
    return state_dir() / LOG_NAME


def env_files():
    """API-key files, first match wins: ~/.config/g2hub/.env, then the original hub/.env."""
    return [config_dir() / '.env', LEGACY_DIR / '.env']


def legacy_hub_state_file():
    return LEGACY_DIR / 'hub_state.json'


def legacy_ai_log_file():
    return LEGACY_DIR / 'even_ai_log.jsonl'


def ensure_dir(path, mode=0o700):
    """Create `path` (and parents) if missing. A directory we create gets `mode`; the hub's own
    data and config dirs are tightened to 0700 even if they already existed."""
    path = Path(path)
    existed = path.exists()
    path.mkdir(parents=True, exist_ok=True)
    if not existed or path.name == APP_ID:
        try:
            os.chmod(path, mode)
        except OSError:
            pass
    return path


def ensure_dirs():
    """Create the data, config and state directories. Returns them as a dict."""
    return {'data': ensure_dir(data_dir()), 'config': ensure_dir(config_dir()),
            'state': ensure_dir(state_dir())}


def _backup_sqlite(src, dst):
    """Consistent copy of a SQLite file, safe even if another process has it open."""
    tmp = Path(str(dst) + '.tmp')
    if tmp.exists():
        tmp.unlink()
    s = sqlite3.connect(f'file:{src}?mode=ro', uri=True)
    try:
        d = sqlite3.connect(tmp)
        try:
            s.backup(d)
        finally:
            d.close()
    finally:
        s.close()
    os.chmod(tmp, 0o600)
    os.replace(tmp, dst)


def migrate_legacy(target_dir=None, legacy_dir=None, log=None):
    """One-time move of hub.db and hn_cache.json from hub/ into the data dir.

    Skipped when the target is the legacy dir itself (G2HUB_DATA_DIR pointing at hub),
    when the marker says it already ran, or when there is nothing to move. A file already present
    in the target is never overwritten (the old one is then left untouched). Returns the list of
    migrated file names."""
    target = Path(target_dir) if target_dir is not None else data_dir()
    legacy = Path(legacy_dir) if legacy_dir is not None else LEGACY_DIR
    log = log or (lambda msg: None)
    try:
        if target.resolve() == legacy.resolve():
            return []
    except OSError:
        pass
    marker = target / MIGRATION_MARKER
    if marker.exists():
        return []
    candidates = [n for n in (DB_NAME, NEWS_CACHE_NAME) if (legacy / n).is_file()]
    if not candidates:
        return []
    ensure_dir(target)
    moved = []
    for name in candidates:
        src, dst = legacy / name, target / name
        if dst.exists():
            log(f'migration: {dst} already exists; leaving {src} in place')
            continue
        if name == DB_NAME:
            _backup_sqlite(src, dst)
        else:
            tmp = Path(str(dst) + '.tmp')
            shutil.copyfile(src, tmp)
            os.chmod(tmp, 0o600)
            os.replace(tmp, dst)
        os.replace(src, legacy / (name + '.migrated'))
        moved.append(name)
        log(f'migration: {src} -> {dst} (original kept as {name}.migrated)')
    marker.write_text(json.dumps({'from': str(legacy), 'files': moved, 'at': int(time.time())}) + '\n')
    try:
        os.chmod(marker, 0o600)
    except OSError:
        pass
    return moved
