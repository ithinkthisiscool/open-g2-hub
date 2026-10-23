"""Logging for the hub: JSON lines to a rotating file, plain text to the console.

    ~/.local/state/g2hub/hub.jsonl   (5 MB x 5 rotated files; G2HUB_STATE_DIR overrides the dir)

Every UI event (hub.events.on_event) is also a log record on the 'g2hub.event' logger, so the file
has the same history as the Live log tab, plus warnings/errors from aiohttp, bleak and the
hub's own modules. A redaction filter masks API keys as a safety net.

Environment: G2HUB_LOG_LEVEL (file, default INFO), G2HUB_CONSOLE_LEVEL (stderr, default WARNING).
(Named logs.py, not logging.py: the hub directory is on sys.path when run as a script.)
"""
import json
import logging
import logging.handlers
import os
import re
import sys
import time

UI_LEVELS = {'info': logging.INFO, 'ok': logging.INFO, 'warn': logging.WARNING, 'err': logging.ERROR}
MAX_BYTES = 5 * 1024 * 1024
BACKUP_COUNT = 5

_SECRET_PATTERNS = [
    (re.compile(r'sk-ant-[A-Za-z0-9_\-]{8,}'), 'sk-ant-***'),
    (re.compile(r'(?i)\b(Token|Bearer)\s+[A-Za-z0-9._\-]{12,}'), r'\1 ***'),
    (re.compile(r'(?i)(x-api-key|api[_-]?key|x-g2hub-token)(["\']?\s*[:=]\s*["\']?)[A-Za-z0-9._\-]{12,}'), r'\1\2***'),
]


def redact(text):
    for pat, repl in _SECRET_PATTERNS:
        text = pat.sub(repl, text)
    return text


class RedactFilter(logging.Filter):
    def filter(self, record):
        msg = record.getMessage()
        red = redact(msg)
        if red != msg:
            record.msg, record.args = red, None
        return True


class JsonFormatter(logging.Formatter):
    def format(self, record):
        out = {'ts': time.strftime('%Y-%m-%dT%H:%M:%S', time.localtime(record.created)) + f'.{int(record.msecs):03d}',
               'level': record.levelname, 'logger': record.name, 'msg': record.getMessage()}
        ui = getattr(record, 'ui_level', None)
        if ui:
            out['ui'] = ui
        data = getattr(record, 'data', None)
        if data:
            out['data'] = data
        if record.exc_info:
            out['exc'] = self.formatException(record.exc_info)
        return json.dumps(out, ensure_ascii=False, default=str)


_configured = {}


def setup(log_file, level=None, console_level=None):
    """Install the file + console handlers on the root logger (idempotent). Returns the file path."""
    if _configured.get('file') == str(log_file):
        return log_file
    level = level or os.environ.get('G2HUB_LOG_LEVEL', 'INFO')
    console_level = console_level or os.environ.get('G2HUB_CONSOLE_LEVEL', 'WARNING')
    root = logging.getLogger()
    for h in _configured.get('handlers', []):
        root.removeHandler(h)
    redactor = RedactFilter()
    fh = logging.handlers.RotatingFileHandler(log_file, maxBytes=MAX_BYTES, backupCount=BACKUP_COUNT,
                                              encoding='utf-8')
    fh.setLevel(level)
    fh.setFormatter(JsonFormatter())
    fh.addFilter(redactor)
    try:
        os.chmod(log_file, 0o600)
    except OSError:
        pass
    ch = logging.StreamHandler(sys.stderr)
    ch.setLevel(console_level)
    ch.setFormatter(logging.Formatter('%(asctime)s %(levelname)s %(name)s: %(message)s', '%H:%M:%S'))
    ch.addFilter(redactor)
    root.addHandler(fh)
    root.addHandler(ch)
    root.setLevel(min(fh.level, ch.level))
    logging.getLogger('aiohttp.access').setLevel(logging.WARNING)   # one line per request is noise
    _configured.update(file=str(log_file), handlers=[fh, ch])
    return log_file
