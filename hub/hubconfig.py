"""Hub-wide settings that belong to this computer, not to a pair of glasses.

Stored as JSON in ~/.config/g2hub/hub.json (0600). Unknown keys are ignored; missing keys take
the defaults below.

    keep_connected_lid_closed   False: when the laptop suspends (lid closed), the hub disconnects
                                the glasses cleanly (holding a logind *delay* lock so it has time)
                                and reconnects on resume. True: while the glasses are connected the
                                hub holds a logind *block* lock on handle-lid-switch + sleep, so
                                closing the lid does not suspend the machine and the link stays up.
"""
import json
import os

from hub import paths

DEFAULTS = {'keep_connected_lid_closed': False}
FILE_NAME = 'hub.json'


def path():
    return paths.config_dir() / FILE_NAME


def load():
    try:
        with open(path()) as f:
            data = json.load(f)
    except (OSError, ValueError):
        data = {}
    return {k: type(v)(data.get(k, v)) for k, v in DEFAULTS.items()}


def save(changes):
    cfg = {**load(), **{k: type(DEFAULTS[k])(v) for k, v in changes.items() if k in DEFAULTS}}
    p = path()
    paths.ensure_dir(p.parent)
    tmp = f'{p}.tmp'
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        json.dump(cfg, f, indent=2)
    os.replace(tmp, p)
    return cfg
