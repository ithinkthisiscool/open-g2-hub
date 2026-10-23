"""Tiny stdlib HTTP client for the G2 hub REST API (no third-party deps).

The hub only accepts requests whose Host is localhost:<port> / 127.0.0.1:<port>, and POSTs must be
application/json. Newer hubs also require the local API token (header X-G2Hub-Token, file
~/.config/g2hub/token, created by hub/auth.py) on state-changing requests; it is sent whenever the
file exists, and requests still work against hubs that have no token yet.

urllib sends Host from the URL, so always talk to http://127.0.0.1:<port>.
"""
import json
import os
import urllib.error
import urllib.request
from pathlib import Path

TOKEN_HEADER = 'X-G2Hub-Token'


def token_path():
    """Where the hub keeps its local API token (same rules as hub/paths.py config_dir())."""
    override = os.environ.get('G2HUB_CONFIG_DIR')
    if override:
        return Path(override).expanduser() / 'token'
    base = os.environ.get('XDG_CONFIG_HOME')
    return (Path(base).expanduser() if base else Path.home() / '.config') / 'g2hub' / 'token'


def read_token():
    """The hub's API token, or None if the hub hasn't created one (older hubs have no token).
    Never creates the file: that is the hub's job (hub/auth.py get_token())."""
    try:
        return token_path().read_text().strip() or None
    except OSError:
        return None


class HubError(Exception):
    pass


class HubClient:
    def __init__(self, base_url, timeout=5.0):
        self.base = base_url.rstrip('/')
        self.timeout = timeout

    def _req(self, method, path, body=None, timeout=None):
        data = None
        headers = {'Accept': 'application/json'}
        token = read_token()            # re-read each time: the hub may create/rotate it later
        if token:
            headers[TOKEN_HEADER] = token
        if method != 'GET':
            data = json.dumps(body or {}).encode()
            headers['Content-Type'] = 'application/json'
        req = urllib.request.Request(self.base + path, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=timeout or self.timeout) as r:
                raw = r.read()
        except urllib.error.HTTPError as e:
            try:
                msg = json.loads(e.read() or b'{}').get('error') or e.reason
            except ValueError:
                msg = e.reason
            raise HubError(f'{e.code}: {msg}') from None
        except (urllib.error.URLError, OSError, TimeoutError) as e:
            raise HubError(f'hub unreachable: {getattr(e, "reason", e)}') from None
        try:
            return json.loads(raw or b'{}')
        except ValueError:
            raise HubError('hub sent a non-JSON reply') from None

    def get(self, path, timeout=None):
        return self._req('GET', path, timeout=timeout)

    def post(self, path, body=None, timeout=None):
        return self._req('POST', path, body, timeout=timeout)

    # --- convenience ---
    def alive(self, timeout=1.5):
        try:
            return isinstance(self.get('/api/status', timeout=timeout), dict)
        except HubError:
            return False

    def status(self):
        return self.get('/api/status')

    def devices(self):
        return self.get('/api/devices')

    def settings(self):
        return self.get('/api/settings')

    def scan(self):
        return self.post('/api/devices/scan', timeout=20)   # hub scans for 8 s

    def select(self, dev_id):
        return self.post('/api/devices/select', {'id': int(dev_id)})

    def notify(self, title, message, display_name=None):
        body = {'title': title, 'message': message}
        if display_name:
            body['display_name'] = display_name
        return self.post('/api/notify_send', body, timeout=15)
