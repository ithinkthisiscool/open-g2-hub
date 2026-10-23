"""The hub's local database: one record per pair of glasses, and everything configured for it.

Why: the official app remembers each pair's widgets and settings and re-applies them when the
glasses connect. This module is the hub's equivalent. It is a single SQLite file
(hub/hub.db, created automatically) with three tables:

    devices   one row per pair of glasses: pair id (from the BLE name "Even G2_<pair>_L_..."),
              both lens MAC addresses, firmware, last seen, and which pair is the default
    config    per-device settings, one JSON document per section
              (calendar, quicklist, menu, even_ai, settings, news, ...), plus the hidden
              '_profiles' / '_profile_schedule' sections (named widget sets, hub/profiles.py)
    ai_log    every Even AI question and answer, per device

The first time it runs it imports the older hub_state.json and even_ai_log.jsonl files, so no
earlier configuration is lost (the old files are left in place, untouched).
"""
import json
import os
import sqlite3
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DB_FILE = os.path.join(HERE, 'hub.db')   # legacy default; the hub passes paths.db_path()

_SCHEMA = """
CREATE TABLE IF NOT EXISTS devices (
    id          INTEGER PRIMARY KEY,
    pair_id     TEXT UNIQUE NOT NULL,
    name        TEXT,
    right_mac   TEXT,
    left_mac    TEXT,
    firmware    TEXT,
    info_json   TEXT,
    created_at  INTEGER NOT NULL,
    last_seen   INTEGER,
    is_default  INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS config (
    device_id   INTEGER NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    section     TEXT NOT NULL,
    data_json   TEXT NOT NULL,
    updated_at  INTEGER NOT NULL,
    PRIMARY KEY (device_id, section)
);
CREATE TABLE IF NOT EXISTS ai_log (
    id          INTEGER PRIMARY KEY,
    device_id   INTEGER REFERENCES devices(id) ON DELETE SET NULL,
    ts          INTEGER NOT NULL,
    entry_json  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ai_log_device_ts ON ai_log(device_id, ts);
"""


class Store:
    """Thread-safe wrapper around the SQLite file. All methods are quick, synchronous calls."""

    def __init__(self, path=DB_FILE):
        self.path = path
        self._lock = threading.Lock()
        self._db = sqlite3.connect(path, check_same_thread=False)
        try:
            os.chmod(path, 0o600)       # per-pair config, AI transcripts, MAC addresses
        except OSError:
            pass
        self._db.row_factory = sqlite3.Row
        self._db.execute('PRAGMA foreign_keys = ON')
        self._db.executescript(_SCHEMA)
        self._db.commit()

    def _exec(self, sql, args=()):
        with self._lock:
            cur = self._db.execute(sql, args)
            self._db.commit()
            return cur

    def _query(self, sql, args=()):
        with self._lock:
            return [dict(r) for r in self._db.execute(sql, args).fetchall()]

    # ── devices ──────────────────────────────────────────────────────────────────────────────
    def devices(self):
        return self._query('SELECT * FROM devices ORDER BY is_default DESC, last_seen DESC')

    def device(self, device_id):
        rows = self._query('SELECT * FROM devices WHERE id = ?', (device_id,))
        return rows[0] if rows else None

    def default_device(self):
        rows = self._query('SELECT * FROM devices ORDER BY is_default DESC, last_seen DESC LIMIT 1')
        return rows[0] if rows else None

    def upsert_device(self, pair_id, right_mac=None, left_mac=None, name=None):
        """Add a pair (or update its addresses). Returns the device id. The first device added
        becomes the default."""
        now = int(time.time())
        existing = self._query('SELECT id FROM devices WHERE pair_id = ?', (pair_id,))
        if existing:
            dev_id = existing[0]['id']
            self._exec('UPDATE devices SET right_mac = COALESCE(?, right_mac), '
                       'left_mac = COALESCE(?, left_mac), name = COALESCE(?, name) WHERE id = ?',
                       (right_mac, left_mac, name, dev_id))
            return dev_id
        is_first = not self._query('SELECT 1 FROM devices LIMIT 1')
        cur = self._exec('INSERT INTO devices (pair_id, name, right_mac, left_mac, created_at, is_default) '
                         'VALUES (?, ?, ?, ?, ?, ?)',
                         (pair_id, name or f'Even G2 {pair_id}', right_mac, left_mac, now, int(is_first)))
        return cur.lastrowid

    def claim_pair(self, device_id, pair_id, right_mac, left_mac):
        """Give a placeholder device (no lens addresses yet) a real pair id and addresses, keeping
        its configuration. Used when the first discovered pair replaces the empty-database seed."""
        self._exec('UPDATE devices SET pair_id = ?, right_mac = ?, left_mac = ?, name = ? WHERE id = ?',
                   (pair_id, right_mac, left_mac, f'Even G2 {pair_id}', device_id))

    def set_default(self, device_id):
        with self._lock:
            self._db.execute('UPDATE devices SET is_default = (id = ?)', (device_id,))
            self._db.commit()

    def rename(self, device_id, name):
        self._exec('UPDATE devices SET name = ? WHERE id = ?', (name, device_id))

    def forget(self, device_id):
        """Delete a pair and all of its configuration and log (cannot be undone)."""
        self._exec('DELETE FROM devices WHERE id = ?', (device_id,))

    def mark_seen(self, device_id, firmware=None, info=None):
        self._exec('UPDATE devices SET last_seen = ?, firmware = COALESCE(?, firmware), '
                   'info_json = COALESCE(?, info_json) WHERE id = ?',
                   (int(time.time()), firmware, json.dumps(info) if info is not None else None, device_id))

    # ── per-device configuration ─────────────────────────────────────────────────────────────
    def get(self, device_id, section, default=None):
        rows = self._query('SELECT data_json FROM config WHERE device_id = ? AND section = ?',
                           (device_id, section))
        return json.loads(rows[0]['data_json']) if rows else default

    def set(self, device_id, section, data):
        self._exec('INSERT INTO config (device_id, section, data_json, updated_at) VALUES (?, ?, ?, ?) '
                   'ON CONFLICT(device_id, section) DO UPDATE SET data_json = excluded.data_json, '
                   'updated_at = excluded.updated_at',
                   (device_id, section, json.dumps(data, ensure_ascii=False), int(time.time())))

    def all_config(self, device_id):
        rows = self._query('SELECT section, data_json FROM config WHERE device_id = ?', (device_id,))
        return {r['section']: json.loads(r['data_json']) for r in rows}

    # ── EvenHub apps in this pair's glasses menu (section 'evenhub_menu') ────────────────────
    # The installed apps themselves are shared by every pair (<data dir>/evenhub/registry.json);
    # which of them sit in the glasses menu is per pair, next to the built-in 'menu' section.
    EVENHUB_MENU = 'evenhub_menu'

    def evenhub_menu(self, device_id):
        """Package ids of the EvenHub apps in this pair's menu, in menu order."""
        data = self.get(device_id, self.EVENHUB_MENU) or {}
        return [p for p in data.get('package_ids', []) if isinstance(p, str)]

    def set_evenhub_menu(self, device_id, package_ids):
        self.set(device_id, self.EVENHUB_MENU, {'package_ids': list(dict.fromkeys(package_ids)),
                                                'pushed_at': int(time.time())})

    # ── profiles (named widget sets) and their schedule — see hub/profiles.py ────────────────
    # Stored as two underscore-prefixed config sections (hidden from state.load_hub_state(), so a
    # profile never captures itself). No schema change: older databases just lack the rows.
    PROFILES = '_profiles'              # {'profiles': {name: {'sections': {...}, 'saved_at': ts}}, 'active': name|None}
    PROFILE_SCHEDULE = '_profile_schedule'   # {'enabled': bool, 'rules': [...], 'last_target': name|None}

    def profiles(self, device_id):
        data = self.get(device_id, self.PROFILES) or {}
        profs = data.get('profiles')
        return {'profiles': profs if isinstance(profs, dict) else {}, 'active': data.get('active')}

    def set_profiles(self, device_id, profiles, active):
        self.set(device_id, self.PROFILES, {'profiles': profiles, 'active': active})

    def profile_schedule(self, device_id):
        data = self.get(device_id, self.PROFILE_SCHEDULE) or {}
        rules = data.get('rules')
        return {'enabled': bool(data.get('enabled', False)), 'rules': rules if isinstance(rules, list) else [],
                'last_target': data.get('last_target')}

    def set_profile_schedule(self, device_id, schedule):
        self.set(device_id, self.PROFILE_SCHEDULE, schedule)

    # ── Even AI log ──────────────────────────────────────────────────────────────────────────
    def add_ai_log(self, device_id, entry):
        entry = {'ts': int(time.time()), **entry}
        self._exec('INSERT INTO ai_log (device_id, ts, entry_json) VALUES (?, ?, ?)',
                   (device_id, entry['ts'], json.dumps(entry, ensure_ascii=False)))
        return entry

    def ai_log(self, device_id, limit=50):
        rows = self._query('SELECT entry_json FROM ai_log WHERE device_id IS ? ORDER BY ts DESC, id DESC LIMIT ?',
                           (device_id, limit))
        return [json.loads(r['entry_json']) for r in rows]

    # ── one-time import of the older JSON files ──────────────────────────────────────────────
    def import_legacy(self, device_id, hub_state_path, ai_log_path):
        """Copy hub_state.json sections and even_ai_log.jsonl entries into this device, once.
        Returns a short description of what was imported ('' if nothing / already done)."""
        if self.get(device_id, '_legacy_imported'):
            return ''
        done = []
        try:
            with open(hub_state_path) as f:
                for section, data in json.load(f).items():
                    if self.get(device_id, section) is None:
                        self.set(device_id, section, data)
                        done.append(section)
        except (FileNotFoundError, ValueError):
            pass
        n = 0
        try:
            with open(ai_log_path) as f:
                for line in f:
                    try:
                        entry = json.loads(line)
                    except ValueError:
                        continue
                    self._exec('INSERT INTO ai_log (device_id, ts, entry_json) VALUES (?, ?, ?)',
                               (device_id, entry.get('ts', int(time.time())), json.dumps(entry)))
                    n += 1
        except FileNotFoundError:
            pass
        self.set(device_id, '_legacy_imported', {'sections': done, 'ai_log_entries': n})
        return f'sections {done}, {n} Even AI log entries' if (done or n) else ''
