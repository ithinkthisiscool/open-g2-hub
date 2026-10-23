"""Local API token for the hub.

Every state-changing request to /api/* (anything but GET/HEAD/OPTIONS) must carry the header
`X-G2Hub-Token: <token>`. The token is random, created on first use and stored in
~/.config/g2hub/token (mode 0600; G2HUB_CONFIG_DIR / XDG_CONFIG_HOME respected). The hub's own
page gets the token embedded when it is served (only same-origin pages can read it), so the
browser UI needs no setup.

Other local clients (the desktop app, scripts) read the same file:

    import sys; sys.path.insert(0, '<repo root>')
    from hub.auth import get_token, HEADER
    headers = {HEADER: get_token(), 'Content-Type': 'application/json'}

or from a shell:  curl -H "X-G2Hub-Token: $(cat ~/.config/g2hub/token)" -H 'Content-Type: application/json' ...

Stdlib only, so it can be imported without the hub's dependencies.
"""
import os
import secrets
from pathlib import Path

try:
    from . import paths
except ImportError:          # imported as a top-level module (hub dir on sys.path)
    import paths

HEADER = 'X-G2Hub-Token'
TOKEN_FILE_NAME = 'token'


def token_path():
    """Path of the token file (it may not exist yet)."""
    return paths.config_dir() / TOKEN_FILE_NAME


def get_token(create=True):
    """Return the hub's API token, creating it (0600) if missing and `create` is true.
    Returns None if it does not exist and create is false."""
    path = token_path()
    try:
        tok = path.read_text().strip()
        if tok:
            return tok
    except FileNotFoundError:
        pass
    if not create:
        return None
    paths.ensure_dir(path.parent)
    tok = secrets.token_urlsafe(32)
    tmp = Path(str(path) + f'.{os.getpid()}.tmp')
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        f.write(tok + '\n')
    try:
        os.link(tmp, path)            # atomic create-if-absent: a concurrent creator wins cleanly
    except FileExistsError:
        tok = path.read_text().strip() or tok
    finally:
        os.unlink(tmp)
    os.chmod(path, 0o600)
    return tok


def auth_enabled():
    """G2HUB_AUTH=0 turns the token check off (transition aid for clients not yet updated)."""
    return os.environ.get('G2HUB_AUTH', '1').strip().lower() not in ('0', 'off', 'false', 'no')
