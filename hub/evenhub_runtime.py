"""EvenHub app runtime: install and run EvenHub (.ehpk) web apps on the G2 without the phone app.

Plain English
-------------
An EvenHub app is a small web app (HTML + JavaScript). In the official setup the phone app runs
it inside a WebView and turns its JavaScript calls ("show this text", "update that list") into
SID 0xE0 messages for the glasses. The glasses never receive the app's code. This module lets
the hub play the phone's part:

    1. Package   read/write .ehpk files (EHPK container, XOR + zstd) and check app.json.
    2. Install   unpack into <data dir>/evenhub/apps/<package_id>/ and give the app a number
                 (app_id). The glasses only ever see that number plus a name.
    3. Menu      put the app in the glasses launcher: one SID 0x03 menu push with
                 {itemType 1, iconNum 1, itemName <=31 chars, itemAppId app_id} next to the
                 built-in items. The official app does exactly this after an install
                 (UnitService._onInstalledPluginsChanged -> _syneMenusToGlass).
    4. Run       serve the app over local HTTP to a headless browser. A small injected script
                 (the "shim") provides window.flutter_inappwebview.callHandler. Plugins written
                 against G2 Hub's own bridge (bridge/g2_hub_bridge.js) call it, and so do
                 third-party .ehpk plugins through the copy of Even's SDK they bundle (we ship
                 no Even SDK; the runtime only answers the calls). Each call reaches
                 EvenHubBridge.call(), which sends the matching SID 0xE0 command and returns
                 the result the SDK expects. Glasses events (clicks, scrolls, IMU, exit) go back
                 to the page through window._listenEvenAppMessage.

Wire contract (what this runtime accepts and sends; G2 Hub's bridge library is written to it,
see docs/evenhub-apps.md):
    page -> host   callHandler('evenAppMessage', '<json string>') where the JSON is
                   {"type": "call_even_app_method", "method": ..., "data": {...}}.
                   The handler's plain return value resolves the SDK promise.
    host -> page   window._listenEvenAppMessage({"type": "listen_even_app_data",
                   "method": "evenHubEvent" | "evenAppLaunchSource" | "deviceStatusChanged",
                   "data": ...}).

Status: everything here is tested OFFLINE only (tests/test_evenhub_runtime.py, fake glasses).
LIVE-CONFIRMED building blocks it reuses: text/list page create (cmd 0), text upgrade (cmd 5),
heartbeat, mic/IMU control, built-in menu push. UNTESTED LIVE: plugin menu items (itemType 1),
the cmd 17 menu-startup launch, textColor/zOrder/menu objects, rebuild (cmd 7), images (cmd 3).
Standalone live test: python/hw_tests/dev/test_ehpk_install.py.

This file uses only g2/ primitives (field encoders, framing, decode_device_event) and encodes
the page messages itself from the app's JSON; it does not change g2/.
"""
import asyncio
import base64
import hashlib
import io
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

_PY_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _PY_DIR not in sys.path:
    sys.path.insert(0, _PY_DIR)

from g2 import evenhub as eh  # noqa: E402
from g2 import menu as g2menu  # noqa: E402
from g2 import limits as lim  # noqa: E402

SID_EVENHUB = eh.SID_EVENHUB
SID_MENU = g2menu.SID_MENU

# ═══════════════════════════════════════════════════════════════════════════════════════════
# 1. EHPK package format
# ═══════════════════════════════════════════════════════════════════════════════════════════
# CONFIRMED from the official CLI's packer output, two store CDN packages and libehpk.so:
#   0  "EHPK"   4 u16 version (1)   6 u16 kind (1 = draft/unsigned, 2 = store-signed)
#   8  u32 offset of the first record   12 u32 record count (footer not counted)
#   16 u32 length of the extra header (0 for kind 1; kind 2: XORed package id follows)
#   records, each starting with a 4-byte marker <type> BA A9 BA:
#     E4 file: u32 compressed_len, u32 size, 01 B7 (constant), u16 name_len, name, data
#     E5 dir : BD AA (constant), u16 name_len, name
#     E3 footer: 64 bytes. Kind 1: SHA-512 of every byte before the E3 marker (CONFIRMED).
#                Kind 2: INFERRED Ed25519 signature; the key comes with the store download.
#   Names and data are XORed with "EVEN REALITIES" (restarting per field); data is zstd.
EHPK_MAGIC = b'EHPK'
EHPK_KEY = b'EVEN REALITIES'
KIND_DRAFT, KIND_SIGNED = 1, 2
_MARK_FILE = b'\xe4\xba\xa9\xba'
_MARK_DIR = b'\xe5\xba\xa9\xba'
_MARK_END = b'\xe3\xba\xa9\xba'
_FILE_CONST = b'\x01\xb7'
_DIR_CONST = b'\xbd\xaa'
ZSTD_MAGIC = b'\x28\xb5\x2f\xfd'


class EhpkError(ValueError):
    pass


# Limits for untrusted packages (a .ehpk from anywhere, or a folder). The official apps are a few
# hundred KB; these leave lots of room and still stop a zip-bomb style package.
MAX_PACKAGE_BYTES = 16 * 1024 * 1024        # the .ehpk file itself
MAX_FILE_BYTES = 16 * 1024 * 1024           # one unpacked file
MAX_UNPACKED_BYTES = 64 * 1024 * 1024       # all unpacked files together
MAX_FILES = 2000                            # records (files + directories)
MAX_PATH_BYTES = 512                        # one member path (UTF-8)
MAX_MANIFEST_BYTES = 64 * 1024              # app.json


def xor_key(data):
    """XOR `data` with the repeating key "EVEN REALITIES" (its own inverse)."""
    k = EHPK_KEY
    return bytes(b ^ k[i % len(k)] for i, b in enumerate(data))


def zstd_raw_frame(data):
    """A valid zstd frame that stores `data` uncompressed (raw blocks). Pure Python, so packing
    works without the zstandard module; any zstd decoder (libehpk's included) reads it."""
    out = bytearray(ZSTD_MAGIC)
    out.append(0xA0)                    # single segment, 4-byte content size, no checksum
    out += struct.pack('<I', len(data))
    block = 128 * 1024
    if not data:
        out += (1).to_bytes(3, 'little')    # last, raw, size 0
        return bytes(out)
    for i in range(0, len(data), block):
        chunk = data[i:i + block]
        last = 1 if i + block >= len(data) else 0
        out += ((len(chunk) << 3) | last).to_bytes(3, 'little') + chunk
    return bytes(out)


def _zstd_decode_simple(frame, limit=None):
    """Decode a zstd frame made only of raw/RLE blocks (what zstd_raw_frame writes). Returns
    None when the frame uses compressed blocks. limit: raise EhpkError past that many bytes."""
    if frame[:4] != ZSTD_MAGIC or len(frame) < 5:
        raise EhpkError('not a zstd frame')
    fhd = frame[4]
    single = (fhd >> 5) & 1
    fcs_flag = fhd >> 6
    did_flag = fhd & 3
    checksum = (fhd >> 2) & 1
    p = 5
    if not single:
        p += 1                                  # window descriptor
    p += (0, 1, 2, 4)[did_flag]
    fcs_len = (1 if single else 0, 2, 4, 8)[fcs_flag]
    p += fcs_len
    out = bytearray()
    while True:
        if p + 3 > len(frame):
            raise EhpkError('truncated zstd frame')
        hdr = int.from_bytes(frame[p:p + 3], 'little')
        p += 3
        last, btype, size = hdr & 1, (hdr >> 1) & 3, hdr >> 3
        if btype == 0:
            if p + size > len(frame):
                raise EhpkError('truncated zstd frame')
            out += frame[p:p + size]
            p += size
        elif btype == 1:
            if limit is not None and len(out) + size > limit:
                raise EhpkError(f'unpacked entry larger than {limit} bytes')
            out += frame[p:p + 1] * size
            p += 1
        else:
            return None
        if limit is not None and len(out) > limit:
            raise EhpkError(f'unpacked entry larger than {limit} bytes')
        if last:
            break
    if checksum:
        p += 4
    return bytes(out)


def zstd_decompress(frame, limit=MAX_FILE_BYTES):
    """Decompress one zstd frame: zstandard module, then the pure-Python raw-block reader, then
    the `zstd` CLI. Never returns more than `limit` bytes (EhpkError instead), so a small
    package cannot expand into gigabytes."""
    try:
        import zstandard
    except ImportError:
        zstandard = None
    if zstandard is not None:
        try:
            with zstandard.ZstdDecompressor().stream_reader(io.BytesIO(frame)) as reader:
                out = reader.read(limit + 1)
        except zstandard.ZstdError as e:
            raise EhpkError(f'zstd: {e}')
        if len(out) > limit:
            raise EhpkError(f'unpacked entry larger than {limit} bytes')
        return out
    simple = _zstd_decode_simple(frame, limit)
    if simple is not None:
        return simple
    if shutil.which('zstd'):
        return _zstd_cli_bounded(frame, limit)
    raise EhpkError('compressed .ehpk entry: install the zstandard module or the zstd CLI')


def _zstd_cli_bounded(frame, limit, timeout=30):
    """`zstd -dc` reading at most limit+1 bytes of output (killed past that or on timeout)."""
    with tempfile.TemporaryFile() as src:
        src.write(frame)
        src.seek(0)
        proc = subprocess.Popen(['zstd', '-dcq'], stdin=src, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            chunks, total = [], 0
            while total <= limit:
                chunk = proc.stdout.read(min(1 << 20, limit + 1 - total))
                if not chunk:
                    break
                chunks.append(chunk)
                total += len(chunk)
            if total > limit:
                raise EhpkError(f'unpacked entry larger than {limit} bytes')
            try:
                err = proc.communicate(timeout=timeout)[1]
            except subprocess.TimeoutExpired:
                raise EhpkError('zstd timed out')
            if proc.returncode != 0:
                raise EhpkError(f'zstd failed: {err.decode(errors="replace").strip()[:200]}')
            return b''.join(chunks)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()


def zstd_compress(data, mode='auto'):
    """mode 'raw' = stored frame (deterministic); 'auto' = real zstd when available."""
    if mode != 'raw':
        try:
            import zstandard
            return zstandard.ZstdCompressor(level=19).compress(data)
        except ImportError:
            pass
        if shutil.which('zstd'):
            res = subprocess.run(['zstd', '-q', '-19', '-c'], input=data, capture_output=True)
            if res.returncode == 0:
                return res.stdout
    return zstd_raw_frame(data)


class Ehpk:
    """A parsed .ehpk: kind, package_id (kind 2 header), files {name: bytes}, dirs, footer."""

    def __init__(self, kind, files, dirs=(), header_package_id='', footer=b'', hash_ok=None):
        self.kind = kind
        self.files = dict(files)
        self.dirs = list(dirs)
        self.header_package_id = header_package_id
        self.footer = footer
        self.hash_ok = hash_ok          # kind 1: SHA-512 footer matched; kind 2: None (not checked)

    @property
    def manifest(self):
        raw = self.files.get('app.json')
        if raw is None:
            raise EhpkError('app.json not found')
        return parse_manifest(raw)

    def dist_files(self):
        """{path relative to dist/: bytes}."""
        return {n[5:]: d for n, d in self.files.items() if n.startswith('dist/')}


def read_ehpk(data, verify=True):
    """Parse .ehpk bytes. verify=True raises when a kind-1 SHA-512 footer does not match.
    Kind-2 (store-signed) signatures are not checked: that needs the per-download public key
    from the authenticated store API (the official app passes it to libehpk).
    The bytes are untrusted: sizes, names and record counts are bounded (MAX_* above), every
    member path is checked (no '..', absolute paths or control characters) and any malformed
    record raises EhpkError."""
    if len(data) > MAX_PACKAGE_BYTES:
        raise EhpkError(f'package larger than {MAX_PACKAGE_BYTES // (1024 * 1024)} MB')
    if data[:4] != EHPK_MAGIC or len(data) < 20:
        raise EhpkError('not an EHPK file (bad magic)')
    try:
        return _read_ehpk(data, verify)
    except (struct.error, UnicodeDecodeError, IndexError) as e:
        raise EhpkError(f'malformed package: {e}')


def _read_ehpk(data, verify):
    _version, kind = struct.unpack_from('<HH', data, 4)
    first, count = struct.unpack_from('<II', data, 8)
    if not 20 <= first <= min(len(data), 20 + 4096):
        raise EhpkError(f'bad first-record offset {first}')
    if count > MAX_FILES:
        raise EhpkError(f'too many records ({count} > {MAX_FILES})')
    if kind == KIND_DRAFT and verify and data[-68:-64] == _MARK_END:
        # Check the hash before parsing, so corruption gives one clear error.
        if hashlib.sha512(data[:-68]).digest() != data[-64:]:
            raise EhpkError('SHA-512 footer mismatch (corrupt draft package)')
    header_pid = ''
    if first > 20:
        header_pid = xor_key(data[20:first]).decode('utf-8', errors='replace')
    files, dirs = {}, []
    p = first
    footer = b''
    hash_ok = None
    n = 0
    total = 0
    while p < len(data):
        if n >= MAX_FILES:
            raise EhpkError(f'too many records (> {MAX_FILES})')
        mark = data[p:p + 4]
        if mark == _MARK_FILE:
            clen, size = struct.unpack_from('<II', data, p + 4)
            nlen = struct.unpack_from('<H', data, p + 14)[0]
            if p + 16 + nlen + clen > len(data):
                raise EhpkError('truncated file record')
            name = xor_key(data[p + 16:p + 16 + nlen]).decode('utf-8')
            _check_member_name(name)
            if name in files:
                raise EhpkError(f'duplicate entry {name!r}')
            if size > MAX_FILE_BYTES:
                raise EhpkError(f'{name}: {size} bytes unpacked (limit {MAX_FILE_BYTES})')
            total += size
            if total > MAX_UNPACKED_BYTES:
                raise EhpkError(f'package unpacks to more than {MAX_UNPACKED_BYTES // (1024 * 1024)} MB')
            body = xor_key(data[p + 16 + nlen:p + 16 + nlen + clen])
            content = zstd_decompress(body, limit=size)
            if len(content) != size:
                raise EhpkError(f'{name}: size {len(content)} != header {size}')
            files[name] = content
            p += 16 + nlen + clen
            n += 1
        elif mark == _MARK_DIR:
            nlen = struct.unpack_from('<H', data, p + 6)[0]
            if p + 8 + nlen > len(data):
                raise EhpkError('truncated directory record')
            dname = xor_key(data[p + 8:p + 8 + nlen]).decode('utf-8')
            _check_member_name(dname)
            dirs.append(dname)
            p += 8 + nlen
            n += 1
        elif mark == _MARK_END:
            footer = data[p + 4:p + 68]
            if kind == KIND_DRAFT:
                hash_ok = hashlib.sha512(data[:p]).digest() == footer
                if verify and not hash_ok:
                    raise EhpkError('SHA-512 footer mismatch (corrupt draft package)')
            break
        else:
            raise EhpkError(f'unknown record marker {mark.hex()} at {p}')
    if count and n != count:
        raise EhpkError(f'record count {n} != header {count}')
    return Ehpk(kind, files, dirs, header_pid, footer, hash_ok)


_UNSAFE_CHARS = re.compile(r'[\x00-\x1f\x7f\\:]')


def _check_member_name(name):
    """A package member path must be relative, '/'-separated, without '.', '..' or empty parts,
    backslashes, drive colons or control characters, and short. Raises EhpkError otherwise."""
    if (not isinstance(name, str) or not name or name.startswith('/') or _UNSAFE_CHARS.search(name)
            or len(name.encode('utf-8')) > MAX_PATH_BYTES
            or any(part in ('..', '.', '') for part in name.split('/'))):
        raise EhpkError(f'unsafe path in package: {name!r}')


def write_ehpk(manifest, dist_files, compress='auto'):
    """Build a kind-1 (draft) .ehpk, the same layout `evenhub pack` writes. manifest: dict or
    app.json bytes; dist_files: {relative path: bytes}. Returns the package bytes."""
    if isinstance(manifest, dict):
        manifest = json.dumps(manifest, separators=(',', ':')).encode('utf-8')
    records = []

    def file_rec(name, content):
        _check_member_name(name)
        nb = xor_key(name.encode('utf-8'))
        comp = xor_key(zstd_compress(content, compress))
        return (_MARK_FILE + struct.pack('<II', len(comp), len(content)) + _FILE_CONST +
                struct.pack('<H', len(nb)) + nb + comp)

    def dir_rec(name):
        nb = xor_key(name.encode('utf-8'))
        return _MARK_DIR + _DIR_CONST + struct.pack('<H', len(nb)) + nb

    records.append(file_rec('app.json', manifest))
    records.append(dir_rec('dist'))
    seen_dirs = {'dist'}
    for rel in sorted(dist_files):
        parts = rel.split('/')
        for i in range(1, len(parts)):
            d = 'dist/' + '/'.join(parts[:i])
            if d not in seen_dirs:
                seen_dirs.add(d)
                records.append(dir_rec(d))
        records.append(file_rec('dist/' + rel, dist_files[rel]))
    body = EHPK_MAGIC + struct.pack('<HHIII', 1, KIND_DRAFT, 20, len(records), 0) + b''.join(records)
    return body + _MARK_END + hashlib.sha512(body).digest()


def pack_directory(app_dir, dist_dir=None, compress='auto'):
    """Pack <app_dir>/app.json + <dist_dir or app_dir/dist> into .ehpk bytes (like
    `evenhub pack app.json dist`). Dotfiles are skipped, as the CLI does by default."""
    app_dir = Path(app_dir)
    dist = Path(dist_dir) if dist_dir else app_dir / 'dist'
    manifest = (app_dir / 'app.json').read_bytes()
    files = {}
    for path in sorted(dist.rglob('*')):
        rel = path.relative_to(dist).as_posix()
        if path.is_file() and not any(part.startswith('.') for part in rel.split('/')):
            files[rel] = path.read_bytes()
    return write_ehpk(manifest, files, compress)


# ═══════════════════════════════════════════════════════════════════════════════════════════
# 2. app.json manifest
# ═══════════════════════════════════════════════════════════════════════════════════════════
PACKAGE_ID_RE = re.compile(r'^[a-z][a-z0-9]*(\.[a-z][a-z0-9]*)+$')
VERSION_RE = re.compile(r'^\d+\.\d+\.\d+$')
PERMISSION_NAMES = {'network', 'location', 'g2-microphone', 'phone-microphone', 'album', 'camera'}
LANGUAGES = {'en', 'de', 'fr', 'es', 'it', 'zh', 'ja', 'ko'}
MENU_NAME_MAX = 31      # getCustomPluginName -> StringUtils.getLimitString(name, 31)


# What the hub accepts as a package id (it becomes a folder name): dotted, ASCII letters, digits,
# '_' and '-'. Stricter than the filesystem needs; looser than PACKAGE_ID_RE (that one is only
# reported as a problem, since early store packages break it).
SAFE_PACKAGE_ID_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_-]*(\.[A-Za-z0-9][A-Za-z0-9_-]*)+$')
_CTRL = re.compile(r'[\x00-\x1f\x7f]')


def parse_manifest(raw):
    """app.json bytes -> dict. Raises EhpkError for oversize, non-UTF-8, bad JSON or a non-object."""
    if len(raw) > MAX_MANIFEST_BYTES:
        raise EhpkError(f'app.json larger than {MAX_MANIFEST_BYTES} bytes')
    try:
        m = json.loads(raw.decode('utf-8') if isinstance(raw, (bytes, bytearray)) else raw)
    except (UnicodeDecodeError, ValueError) as e:
        raise EhpkError(f'app.json is not valid JSON: {e}')
    if not isinstance(m, dict):
        raise EhpkError('app.json must be a JSON object')
    return m


def check_manifest(m):
    """Hard checks before anything is written to disk (the manifest is untrusted): a safe
    package_id, a safe entrypoint path, and string name/version. Raises EhpkError. Soft schema
    problems are reported by validate_manifest() instead."""
    pid = m.get('package_id')
    if not isinstance(pid, str) or len(pid) > 128 or not SAFE_PACKAGE_ID_RE.match(pid) \
            or pid.endswith(('.installing', '.backup')):
        raise EhpkError(f'bad package_id {str(pid)[:80]!r} (expected something like com.example.app)')
    entry = m.get('entrypoint', 'index.html')
    if not isinstance(entry, str):
        raise EhpkError('entrypoint must be a string')
    _check_member_name(entry or 'index.html')
    for key in ('name', 'version'):
        if m.get(key) is not None and not isinstance(m.get(key), str):
            raise EhpkError(f'{key} must be a string')


def clean_text(value, limit):
    """A display string from the manifest: str, control characters removed, at most `limit`
    characters. (HTML escaping is the page's job.)"""
    return _CTRL.sub('', str(value if value is not None else ''))[:limit]


def normalize_permissions(perms):
    """Both shapes seen in the wild -> [{'name', 'desc', 'whitelist'?}]. New (CLI schema):
    a list of {name, desc, whitelist?}. Old (early store packages): {"network": [hosts], ...}."""
    if isinstance(perms, dict):
        out = []
        for name, value in perms.items():
            entry = {'name': name, 'desc': ''}
            if isinstance(value, list):
                entry['whitelist'] = value
            out.append(entry)
        return out
    return [p for p in (perms if isinstance(perms, list) else []) if isinstance(p, dict)]


def display_permissions(perms):
    """normalize_permissions() reduced to short display strings (for the registry and the UI)."""
    out = []
    for p in normalize_permissions(perms)[:20]:
        entry = {'name': clean_text(p.get('name'), 40), 'desc': clean_text(p.get('desc'), 300)}
        wl = p.get('whitelist')
        if isinstance(wl, list):
            entry['whitelist'] = [clean_text(h, 200) for h in wl[:20]]
        out.append(entry)
    return out


def validate_manifest(m):
    """Problems (strings) against the CLI's app.json schema. Empty list = valid. Old-style
    packages from the store fail some rules (no supported_languages, map permissions); the
    runtime still runs them and only reports the problems."""
    problems = []
    pid = m.get('package_id', '')
    if not isinstance(pid, str) or not PACKAGE_ID_RE.match(pid):
        problems.append(f'package_id {clean_text(pid, 80)!r} must look like com.example.app (lowercase, no dashes)')
    if m.get('edition') != '202601':
        problems.append('edition must be "202601"')
    name = m.get('name') or ''
    if not isinstance(name, str) or not name or len(name) > 20:
        problems.append('name must be 1-20 characters')
    if not isinstance(m.get('version'), str) or not VERSION_RE.match(m.get('version')):
        problems.append('version must be x.y.z')
    if not m.get('entrypoint'):
        problems.append('entrypoint is required (e.g. index.html)')
    if not isinstance(m.get('min_sdk_version'), str):
        problems.append('min_sdk_version (string) is required')
    perms = m.get('permissions')
    if not isinstance(perms, list):
        problems.append('permissions must be a list of {name, desc}')
    else:
        for p in perms[:50]:
            if not isinstance(p, dict) or not isinstance(p.get('name'), str) or p.get('name') not in PERMISSION_NAMES:
                problems.append(f'unknown permission {clean_text(p, 80)!r}')
            elif not isinstance(p.get('desc'), str) or not 1 <= len(p.get('desc') or '') <= 300:
                problems.append(f'permission {p["name"]}: desc must be 1-300 characters')
    langs = m.get('supported_languages')
    if not isinstance(langs, list) or not langs or not all(isinstance(x, str) for x in langs) \
            or not set(langs) <= LANGUAGES:
        problems.append(f'supported_languages must be a non-empty subset of {sorted(LANGUAGES)}')
    if len(str(m.get('tagline') or '')) > 50:
        problems.append('tagline must be 50 characters or fewer')
    if len(str(m.get('description') or '')) > 1024:
        problems.append('description must be 1024 characters or fewer')
    return problems


def menu_name(name):
    """The name the official app puts in the glasses menu: at most 31 characters, 'custom' if
    empty. Control characters are dropped (the name is untrusted)."""
    name = _CTRL.sub('', name if isinstance(name, str) else '').strip()
    return name[:MENU_NAME_MAX] if name else 'custom'


def has_network_permission(app):
    """True when the app's manifest asks for the 'network' permission."""
    return any(p.get('name') == 'network' for p in app.get('permissions') or [])


# ═══════════════════════════════════════════════════════════════════════════════════════════
# 3. Installed apps (registry)
# ═══════════════════════════════════════════════════════════════════════════════════════════
FIRST_APP_ID = 20001    # our own numbering; store apps use their store id (LocalPluginState.id)


def default_root():
    """<g2hub data dir>/evenhub (XDG, see hub/paths.py)."""
    try:
        from hub import paths
        return Path(paths.data_dir()) / 'evenhub'
    except Exception:
        return Path.home() / '.local' / 'share' / 'g2hub' / 'evenhub'


class AppRegistry:
    """Installed EvenHub apps on disk:
        <root>/registry.json           {package_id: {app_id, name, version, entrypoint, ...}}
        <root>/apps/<package_id>/      app.json + the unpacked dist/ files
        <root>/storage/<package_id>.json   the app's setLocalStorage values
    Install replaces an older version atomically (unpack to .installing, swap, drop .backup),
    as EhPluginInstallTransaction does."""

    def __init__(self, root=None):
        self.root = Path(root) if root else default_root()
        self.apps_dir = self.root / 'apps'
        self.storage_dir = self.root / 'storage'
        self.path = self.root / 'registry.json'

    def load(self):
        try:
            return json.loads(self.path.read_text())
        except (OSError, ValueError):
            return {}

    def _save(self, reg):
        self.root.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix('.tmp')
        tmp.write_text(json.dumps(reg, indent=2, sort_keys=True))
        os.replace(tmp, self.path)

    def get(self, key):
        """Look up by package_id or by app_id (int)."""
        reg = self.load()
        if isinstance(key, int) or (isinstance(key, str) and key.isdigit()):
            for entry in reg.values():
                if entry['app_id'] == int(key):
                    return entry
            return None
        return reg.get(key)

    def list(self):
        return sorted(self.load().values(), key=lambda e: e['app_id'])

    def app_dir(self, package_id):
        return self.apps_dir / package_id

    def install(self, source, app_id=None, source_label=None):
        """Install from a .ehpk path, .ehpk bytes, or a directory holding app.json (+ dist/).
        Returns the registry entry. app_id: keep the existing one, else the given one, else the
        next free number from FIRST_APP_ID."""
        kind = 'folder'
        if isinstance(source, (bytes, bytearray)):
            pkg = read_ehpk(bytes(source))
            manifest, files, label = pkg.manifest, pkg.dist_files(), source_label or 'bytes'
            kind = _kind_label(pkg)
        else:
            src = Path(source)
            if src.is_dir():
                manifest, files = read_app_folder(src)
                label = source_label or str(src)
            else:
                if src.stat().st_size > MAX_PACKAGE_BYTES:
                    raise EhpkError(f'package larger than {MAX_PACKAGE_BYTES // (1024 * 1024)} MB')
                pkg = read_ehpk(src.read_bytes())
                manifest, files, label = pkg.manifest, pkg.dist_files(), source_label or str(src)
                kind = _kind_label(pkg)
        check_manifest(manifest)
        pid = manifest['package_id']
        entry_name = manifest.get('entrypoint') or 'index.html'
        if entry_name not in files:
            raise EhpkError(f'entrypoint {entry_name!r} not in package (have {sorted(files)[:8]})')
        reg = self.load()
        old = reg.get(pid)
        if old:
            app_id = old['app_id']
        elif app_id is None:
            used = {e['app_id'] for e in reg.values()}
            app_id = FIRST_APP_ID
            while app_id in used:
                app_id += 1
        final = self.app_dir(pid)
        staging = final.with_name(pid + '.installing')
        backup = final.with_name(pid + '.backup')
        shutil.rmtree(staging, ignore_errors=True)
        dist_root = (staging / 'dist').resolve()
        try:
            for rel, content in files.items():
                _check_member_name(rel)
                dest = staging / 'dist' / rel
                if not dest.resolve().is_relative_to(dist_root):      # belt and braces
                    raise EhpkError(f'unsafe path in package: {rel!r}')
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(content)
            (staging / 'app.json').write_text(json.dumps(manifest, indent=2))
        except BaseException:
            shutil.rmtree(staging, ignore_errors=True)
            raise
        shutil.rmtree(backup, ignore_errors=True)
        if final.exists():
            os.replace(final, backup)
        os.replace(staging, final)
        shutil.rmtree(backup, ignore_errors=True)
        entry = {
            'package_id': pid, 'app_id': int(app_id), 'name': clean_text(manifest.get('name') or pid, 64),
            'menu_name': menu_name(manifest.get('name') or pid),
            'version': clean_text(manifest.get('version', ''), 32), 'entrypoint': entry_name,
            'permissions': display_permissions(manifest.get('permissions')),
            'problems': [clean_text(p, 300) for p in validate_manifest(manifest)][:30],
            'source': clean_text(label, 300), 'kind': kind,
            'installed_at': int(time.time()), 'in_menu': old.get('in_menu', True) if old else True,
        }
        reg[pid] = entry
        self._save(reg)
        return entry

    def uninstall(self, package_id):
        reg = self.load()
        if not isinstance(package_id, str) or reg.pop(package_id, None) is None:
            return False
        shutil.rmtree(self.app_dir(package_id), ignore_errors=True)
        self._save(reg)
        return True


def _kind_label(pkg):
    if pkg.kind == KIND_DRAFT:
        return 'draft (SHA-512 ok)' if pkg.hash_ok else 'draft (no footer)'
    return 'store-signed (signature NOT verified)'


def read_app_folder(src):
    """(manifest, {path relative to dist/: bytes}) from an app folder: app.json plus dist/ (or
    the folder itself). Symlinks are skipped (they could point anywhere), as are dotfiles; the
    same size limits as a .ehpk apply."""
    src = Path(src)
    mpath = src / 'app.json'
    if not mpath.is_file() or mpath.is_symlink():
        raise EhpkError(f'no app.json in {src}')
    if mpath.stat().st_size > MAX_MANIFEST_BYTES:
        raise EhpkError(f'app.json larger than {MAX_MANIFEST_BYTES} bytes')
    manifest = parse_manifest(mpath.read_bytes())
    dist = src / 'dist' if (src / 'dist').is_dir() and not (src / 'dist').is_symlink() else src
    files, total = {}, 0
    for root, dirnames, filenames in os.walk(dist, followlinks=False):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith('.')
                             and not os.path.islink(os.path.join(root, d)))
        for fn in sorted(filenames):
            path = Path(root) / fn
            rel = path.relative_to(dist).as_posix()
            if fn.startswith('.') or path.is_symlink() or not path.is_file() or (dist == src and rel == 'app.json'):
                continue
            _check_member_name(rel)
            size = path.stat().st_size
            total += size
            if size > MAX_FILE_BYTES or total > MAX_UNPACKED_BYTES:
                raise EhpkError(f'app folder too large ({rel})')
            if len(files) >= MAX_FILES:
                raise EhpkError(f'too many files (> {MAX_FILES})')
            files[rel] = path.read_bytes()
    return manifest, files


# ═══════════════════════════════════════════════════════════════════════════════════════════
# 4. SDK JSON -> SID 0xE0 protobuf (field numbers: docs/protocol.md, SID 0xE0)
# ═══════════════════════════════════════════════════════════════════════════════════════════
CMD_CREATE, CMD_CREATE_ACK = 0, 1
CMD_EVENT = 2
CMD_IMAGE, CMD_IMAGE_ACK = 3, 4
CMD_TEXT, CMD_TEXT_ACK = 5, 6
CMD_REBUILD, CMD_REBUILD_ACK = 7, 8
CMD_SHUTDOWN, CMD_SHUTDOWN_ACK = 9, 10
CMD_AUDIO, CMD_AUDIO_ACK = 15, 16
CMD_MENU_STARTUP = 17
CMD_MENU_STARTUP_FAILED = 18
CMD_IMU, CMD_IMU_ACK = 19, 20
# envelope field that carries each command's body / its ack body
FIELD = {CMD_CREATE: 3, CMD_CREATE_ACK: 4, CMD_IMAGE: 5, CMD_IMAGE_ACK: 6, CMD_REBUILD: 7,
         CMD_REBUILD_ACK: 8, CMD_TEXT: 9, CMD_TEXT_ACK: 10, CMD_SHUTDOWN: 11,
         CMD_SHUTDOWN_ACK: 12, CMD_AUDIO: 18, CMD_AUDIO_ACK: 19, CMD_MENU_STARTUP_FAILED: 21,
         CMD_IMU: 22, CMD_IMU_ACK: 23}
# EvenHub_ErrorCode_List success values per ack
OK_CODE = {CMD_CREATE_ACK: 0, CMD_IMAGE_ACK: 4, CMD_REBUILD_ACK: 6, CMD_TEXT_ACK: 8,
           CMD_SHUTDOWN_ACK: 10, CMD_AUDIO_ACK: 13}

MAX_CONTAINERS, MAX_TEXT, MAX_MENU_ITEMS, MENU_ITEM_NAME_BYTES = 12, 8, 10, 32
SCREEN_W, SCREEN_H = 576, 288


def _v(field, value):
    return eh.encode_varint_field(field, int(value))


def _opt(d, key, field):
    """Varint field only when the JSON has the key (and it is not null)."""
    value = d.get(key)
    return _v(field, value) if value is not None else b''


def _geometry(d):
    return (_v(1, d.get('xPosition', 0)) + _v(2, d.get('yPosition', 0)) +
            _v(3, d.get('width', 0)) + _v(4, d.get('height', 0)) +
            _opt(d, 'borderWidth', 5) + _opt(d, 'borderColor', 6) +
            _opt(d, 'borderRadius', 7) + _opt(d, 'paddingLength', 8))


def _name(d, key='containerName'):
    """Container name, cut to the firmware's 15-byte cap (g2.limits)."""
    return lim.utf8_fit(d.get(key, '') or '', lim.EVENHUB_NAME_MAX_BYTES)


def encode_text_container(d):
    """TextContainerProperty {1-4 x y w h, 5-8 border/padding, 9 id, 10 name, 11 isEventCapture,
    12 content, 13 zOrderIndex, 14 TextColor}. Same order as the LIVE-CONFIRMED
    g2.evenhub.encode_text_object; 13/14 are written only when the app sets them."""
    out = _geometry(d) + _v(9, d.get('containerID', 0)) + eh.encode_string_field(10, _name(d))
    if d.get('isEventCapture'):
        out += _v(11, 1)
    out += eh.encode_string_field(12, lim.utf8_fit(d.get('content', '') or '', lim.EVENHUB_TEXT_MAX_BYTES))
    out += _opt(d, 'zOrderIndex', 13) + _opt(d, 'textColor', 14)
    return out


def encode_list_container(d):
    """ListContainerProperty {1-8 as text, 9 id, 10 name, 11 ItemContainer, 12 isEventCapture,
    13 zOrderIndex}; ItemContainer {1 itemCount, 2 itemWidth, 3 isItemSelectBorderEn,
    4 itemName[]}. The LIVE-CONFIRMED g2 encoder always writes 3 = 1 (select border on); we
    keep that default when the app does not say."""
    items = d.get('itemContainer') or {}
    names = [str(n) for n in (items.get('itemName') or [])]
    inner = _v(1, items.get('itemCount', len(names)))
    if items.get('itemWidth') is not None:
        inner += _v(2, items['itemWidth'])
    inner += _v(3, items.get('isItemSelectBorderEn', 1))
    for n in names:
        inner += eh.encode_string_field(4, lim.utf8_fit(n, lim.EVENHUB_LIST_ITEM_MAX_BYTES))
    out = _geometry(d) + _v(9, d.get('containerID', 0)) + eh.encode_string_field(10, _name(d))
    out += eh.encode_message_field(11, inner)
    if d.get('isEventCapture'):
        out += _v(12, 1)
    return out + _opt(d, 'zOrderIndex', 13)


def encode_image_container(d):
    """ImageContainerProperty {1-4 x y w h, 5 id, 6 name, 7 zOrderIndex} (no borders)."""
    return (_v(1, d.get('xPosition', 0)) + _v(2, d.get('yPosition', 0)) + _v(3, d.get('width', 0)) +
            _v(4, d.get('height', 0)) + _v(5, d.get('containerID', 0)) +
            eh.encode_string_field(6, _name(d)) + _opt(d, 'zOrderIndex', 7))


def encode_menu_container(d):
    """MenuContainerProperty {1 MenuItemProperty[]}; MenuItemProperty {1 ItemName, 2 ItemID}.
    (Fields 3 Position, 4 SubItems, 5 CheckedIndex exist in the proto; SDK 0.0.16 sends none.)"""
    out = b''
    for item in (d or {}).get('menuItems') or []:
        out += eh.encode_message_field(1, eh.encode_string_field(1, item.get('itemName', '')) +
                                       _v(2, item.get('itemID', 0)))
    return out


def _page_body(d):
    lists = d.get('listObject') or []
    texts = d.get('textObject') or []
    images = d.get('imageObject') or []
    total = d.get('containerTotalNum') or (len(lists) + len(texts) + len(images))
    out = _v(1, total)
    for x in lists:
        out += eh.encode_message_field(2, encode_list_container(x))
    for x in texts:
        out += eh.encode_message_field(3, encode_text_container(x))
    for x in images:
        out += eh.encode_message_field(4, encode_image_container(x))
    return out


def build_create_page(magic, d, widget_id=eh.DEFAULT_WIDGET_ID, session_id=None):
    """cmd 0, envelope field 3: CreateStartUpPageContainer {1 total, 2 list[], 3 text[],
    4 image[], 5 widgetId, 6 MenuObject, 7 sessionId}."""
    body = _page_body(d) + _v(5, widget_id)
    if d.get('menuObject') and d['menuObject'].get('menuItems'):
        body += eh.encode_message_field(6, encode_menu_container(d['menuObject']))
    if session_id is not None:
        body += _v(7, session_id)
    return eh.wrap_even_hub(CMD_CREATE, magic, FIELD[CMD_CREATE], body)


def build_rebuild_page(magic, d):
    """cmd 7, envelope field 7: RebuildPageContainer {1 total, 2 list[], 3 text[], 4 image[],
    5 MenuObject}. No widgetId/sessionId."""
    body = _page_body(d)
    if d.get('menuObject') and d['menuObject'].get('menuItems'):
        body += eh.encode_message_field(5, encode_menu_container(d['menuObject']))
    return eh.wrap_even_hub(CMD_REBUILD, magic, FIELD[CMD_REBUILD], body)


def build_text_upgrade(magic, d):
    """cmd 5, envelope field 9: TextContainerUpgrade {1 id, 2 name, 3 offset, 4 length,
    5 content, 6 TextColor}. Same layout as the LIVE-CONFIRMED g2 builder plus field 6."""
    content = lim.utf8_fit(d.get('content', '') or '', lim.EVENHUB_TEXT_UPGRADE_MAX_BYTES)
    length = d.get('contentLength')
    if length is None:
        length = len(content.encode('utf-8'))
    body = (_v(1, d.get('containerID', 0)) + eh.encode_string_field(2, _name(d)) +
            _v(3, d.get('contentOffset', 0) or 0) + _v(4, length) + eh.encode_string_field(5, content))
    body += _opt(d, 'textColor', 6)
    return eh.wrap_even_hub(CMD_TEXT, magic, FIELD[CMD_TEXT], body)


def build_shutdown(magic, exit_mode=0):
    """cmd 9, envelope field 11: ShutDownContaniner {1 exitMode}; 0 = exit now, 1 = the glasses
    ask the user first."""
    return eh.wrap_even_hub(CMD_SHUTDOWN, magic, FIELD[CMD_SHUTDOWN], _v(1, exit_mode))


def build_menu_startup_failed(magic, error_code=1, error_string='app not found'):
    """cmd 18, envelope field 21: MenuStartUpResPonse {1 errorCode, 2 errorString}; the reply
    to a cmd 17 launch we cannot serve. INFERRED usage."""
    body = _v(1, error_code) + eh.encode_string_field(2, error_string)
    return eh.wrap_even_hub(CMD_MENU_STARTUP_FAILED, magic, FIELD[CMD_MENU_STARTUP_FAILED], body)


def ack_code(pb, ack_cmd):
    """Result code from an ack protobuf, or None when pb is not that ack. An empty or missing
    body reads as 0 (zeros are left out on the wire)."""
    if pb is None or eh.read_varint_field(pb, 1, 0) != ack_cmd:
        return None
    sub = eh.read_bytes_field(pb, FIELD[ack_cmd])
    if sub is None:
        return 0
    field = 8 if ack_cmd == CMD_IMAGE_ACK else 1
    return eh.read_varint_field(sub, field, 0)


def validate_page(d):
    """SDK-side page rules (README 'Rules'). Returns a list of problems; empty = OK."""
    problems = []
    lists = d.get('listObject') or []
    texts = d.get('textObject') or []
    images = d.get('imageObject') or []
    containers = lists + texts + images
    if not 1 <= len(containers) <= MAX_CONTAINERS:
        problems.append(f'{len(containers)} containers (1-{MAX_CONTAINERS} allowed)')
    if len(texts) > MAX_TEXT:
        problems.append(f'{len(texts)} text containers (max {MAX_TEXT})')
    captures = sum(1 for c in lists + texts if c.get('isEventCapture'))
    if captures != 1:
        problems.append(f'{captures} containers with isEventCapture (exactly 1 expected)')
    ids = [c.get('containerID') for c in containers]
    if len(set(ids)) != len(ids):
        problems.append('duplicate containerID')
    z = [c.get('zOrderIndex') for c in containers]
    if any(v is not None for v in z):
        if any(v is None for v in z):
            problems.append('zOrderIndex set on some containers but not all')
        elif len(set(z)) != len(z):
            problems.append('duplicate zOrderIndex')
    for c in lists:
        n_items = len((c.get('itemContainer') or {}).get('itemName') or [])
        if n_items > lim.EVENHUB_LIST_MAX_ITEMS:
            problems.append(f'list container has {n_items} items (firmware max {lim.EVENHUB_LIST_MAX_ITEMS})')
    for c in texts:
        color = c.get('textColor')
        if color is not None and not 0 <= int(color) <= 4:
            problems.append(f'textColor {color} outside 0-4')
    menu = (d.get('menuObject') or {}).get('menuItems') or []
    if len(menu) > MAX_MENU_ITEMS:
        problems.append(f'{len(menu)} menu items (max {MAX_MENU_ITEMS})')
    mids = [m.get('itemID') for m in menu]
    if any(not i for i in mids) or len(set(mids)) != len(mids):
        problems.append('menu itemID must be non-zero and unique')
    if any(len((m.get('itemName') or '').encode('utf-8')) > MENU_ITEM_NAME_BYTES for m in menu):
        problems.append(f'menu itemName over {MENU_ITEM_NAME_BYTES} UTF-8 bytes')
    return problems


# ═══════════════════════════════════════════════════════════════════════════════════════════
# 5. Glasses events -> SDK evenHubEvent payloads
# ═══════════════════════════════════════════════════════════════════════════════════════════
EXIT_EVENTS = (eh.EVENT_FOREGROUND_EXIT, eh.EVENT_ABNORMAL_EXIT, eh.EVENT_SYSTEM_EXIT)


def sdk_event(event):
    """g2.evenhub.decode_device_event() dict -> the `data` of an evenHubEvent push, i.e.
    {"type": "listEvent"|"textEvent"|"sysEvent"|"menuItemClickEvent", "jsonData": {...}},
    or None for events the page does not get (menu-startup is the host's)."""
    kind = event.get('type')
    if kind == 'list-click':
        return {'type': 'listEvent', 'jsonData': {
            'containerID': event['container_id'], 'containerName': event['container_name'],
            'currentSelectItemName': event['item_name'],
            'currentSelectItemIndex': event['item_index'], 'eventType': event['event_type']}}
    if kind == 'text-click':
        return {'type': 'textEvent', 'jsonData': {
            'containerID': event['container_id'], 'containerName': event['container_name'],
            'eventType': event['event_type']}}
    if kind == 'sys-event':
        data = {'eventType': event['event_type'], 'eventSource': event.get('event_source', 0)}
        if 'imu' in event:
            data['imuData'] = dict(event['imu'])
        if event.get('exit_reason'):
            data['systemExitReasonCode'] = event['exit_reason']
        return {'type': 'sysEvent', 'jsonData': data}
    if kind == 'menu-item-click':
        return {'type': 'menuItemClickEvent', 'jsonData': {'itemID': event['item_id']}}
    return None


# ═══════════════════════════════════════════════════════════════════════════════════════════
# 6. Glasses menu (SID 0x03)
# ═══════════════════════════════════════════════════════════════════════════════════════════
DEFAULT_BUILTINS = [1, 4, 5, 6, 7]      # Dashboard, Notifications, Translate, Teleprompt, Even AI
PLUGIN_ICON_NUM = 1                     # UnitService: DashboardMenuItemType(itemType 1, iconNum 1, ...)


def menu_items(builtin_ids, apps):
    """Ordered [(item_type, icon, name, app_id)] for the push: built-ins first (their order),
    then the apps. apps: registry entries or (name, app_id) pairs."""
    items = [(g2menu.ITEM_TYPE_BUILTIN, 0, '', int(i)) for i in builtin_ids]
    for app in apps:
        name, app_id = (app['menu_name'], app['app_id']) if isinstance(app, dict) else app
        items.append((g2menu.ITEM_TYPE_PLUGIN, PLUGIN_ICON_NUM, menu_name(name), int(app_id)))
    return items


def build_menu_push(magic, builtin_ids, apps):
    """Whole-menu replacement: built-ins as {1: 0, 4: id} (the LIVE-CONFIRMED form, no icon or
    name) and plugins as {1: 1, 2: 1, 3: name, 4: app_id} (UNTESTED live; the form the
    official app builds). 5-10 items in total (MENU_MIN_ITEMS..MENU_MAX_ITEMS)."""
    items = menu_items(builtin_ids, apps)
    if not g2menu.MENU_MIN_ITEMS <= len(items) <= g2menu.MENU_MAX_ITEMS:
        raise ValueError(f'menu needs {g2menu.MENU_MIN_ITEMS}-{g2menu.MENU_MAX_ITEMS} items, got {len(items)}')
    ids = [it[3] for it in items]
    if len(set(ids)) != len(ids):
        raise ValueError(f'duplicate itemAppId in menu: {ids}')
    send = _v(1, len(items))
    for item_type, icon, name, app_id in items:
        if item_type == g2menu.ITEM_TYPE_BUILTIN:
            send += eh.encode_message_field(2, g2menu.encode_builtin_menu_item(app_id))
        else:
            send += eh.encode_message_field(2, g2menu.encode_menu_item(item_type, icon, name, app_id))
    return _v(1, g2menu.CMD_APP_SEND_MENU_INFO) + _v(2, magic) + eh.encode_message_field(3, send)


# ═══════════════════════════════════════════════════════════════════════════════════════════
# 7. Images (EXPERIMENTAL: the CompressMode and pixel packing the firmware wants are unknown)
# ═══════════════════════════════════════════════════════════════════════════════════════════
IMAGE_FRAGMENT_BYTES = 200      # INFERRED; the app's scheduler size was not recovered
IMG_OK, IMG_EXCEPTION, IMG_SIZE_INVALID, IMG_SEND_FAILED = 0, 1, 2, 3


def image_bytes_from_json(value):
    """imageData as the SDK sends it: a number list, or a base64 string."""
    if value is None:
        return b''
    if isinstance(value, str):
        return base64.b64decode(value.split(',', 1)[-1])
    return bytes(int(x) & 0xFF for x in value)


def image_to_gray4(data, width, height):
    """PNG/JPEG/BMP/GIF (via Pillow), 8-bit grey of width*height, or packed 4-bit grey of
    ceil(width*height/2) -> packed 4-bit grey (high nibble = left pixel), resized to the
    container. Raises ValueError when the bytes are none of those."""
    area = width * height
    if len(data) == (area + 1) // 2 and width % 2 == 0:
        return data
    if len(data) == area:
        return eh.pack_4bpp([b >> 4 for b in data], width, height)
    from PIL import Image
    img = Image.open(io.BytesIO(data))
    img = img.convert('LA') if img.mode in ('RGBA', 'LA', 'P') else img.convert('L')
    if img.mode == 'LA':
        bg = Image.new('L', img.size, 0)
        bg.paste(img.convert('L'), mask=img.getchannel('A'))
        img = bg
    if img.size != (width, height):
        img = img.resize((width, height))
    return eh.pack_4bpp([p >> 4 for p in img.getdata()], width, height)


# ═══════════════════════════════════════════════════════════════════════════════════════════
# 8. The bridge: SDK method calls -> glasses
# ═══════════════════════════════════════════════════════════════════════════════════════════
class EvenHubBridge:
    """Host side of callHandler('evenAppMessage', ...) for ONE running app.

    glasses: an object with next_magic() and async request(sid, payload, magic, label=...,
    timeout_s=...) -> reply protobuf or None, e.g. g2.session.GlassesSession (or a fake).
    push(method, data): coroutine function that delivers a host->page message.
    widget_id / session_id: written into cmd 0 (session_id None = field left out, like every
    LIVE-CONFIRMED page so far)."""

    def __init__(self, app, glasses, storage_dir, push=None, widget_id=eh.DEFAULT_WIDGET_ID,
                 session_id=None, user_name='G2 Hub', log=print, on_exit=None,
                 assume_create_ok=True, on_call=None):
        self.app = app
        self.on_call = on_call          # optional fn(method, data, result) after every SDK call
        self.glasses = glasses
        self.storage_path = Path(storage_dir) / f'{app["package_id"]}.json'
        self.push = push
        self.widget_id = widget_id
        self.session_id = session_id
        self.user_name = user_name
        self.log = log
        self.on_exit = on_exit
        self.assume_create_ok = assume_create_ok
        self.page = None                # last page JSON sent (create or rebuild)
        self.page_created = False
        self.image_session = 0
        self.calls = []                 # (method, data, result) history, for tests and logs
        self.battery = None

    # ── transport ──
    async def _request(self, payload, magic, label, timeout_s=3.0):
        return await self.glasses.request(SID_EVENHUB, payload, magic, label=label, timeout_s=timeout_s)

    # ── entry point ──
    async def handle(self, handler_name, args):
        """One callHandler(handler_name, *args). Returns the value that resolves the page's promise."""
        if handler_name == 'evenHubRuntimeUncaughtException':
            self.log(f'[{self.app["package_id"]}] page error: {args[0] if args else ""}')
            return True
        if handler_name != 'evenAppMessage':
            self.log(f'[{self.app["package_id"]}] unknown handler {handler_name}')
            return None
        msg = args[0] if args else {}
        if isinstance(msg, str):
            msg = json.loads(msg)
        if not isinstance(msg, dict):
            return None
        data = msg.get('data') or {}
        return await self.call(str(msg.get('method', ''))[:64], data if isinstance(data, dict) else {})

    async def call(self, method, data):
        fn = getattr(self, 'm_' + method, None)
        try:
            result = await fn(data) if fn else None
        except Exception as e:     # a bad call must not kill the host
            self.log(f'[{self.app["package_id"]}] {method} failed: {e!r}')
            result = None
        if fn is None:
            self.log(f'[{self.app["package_id"]}] unhandled method {method}')
        self.calls.append((method, data, result))
        del self.calls[:-200]           # bounded: a chatty app must not grow memory forever
        if self.on_call is not None:
            try:
                self.on_call(method, data, result)
            except Exception:
                pass
        return result

    # ── host data ──
    async def m_getUserInfo(self, data):
        return {'uid': 0, 'name': self.user_name, 'avatar': '', 'country': ''}

    async def m_getGlassesInfo(self, data):
        if self.battery is None and hasattr(self.glasses, 'query_settings'):
            try:
                info = await self.glasses.query_settings()
                self.battery = (info or {}).get('battery')
            except Exception:
                pass
        return {'model': 'g2', 'sn': '', 'status': self.device_status()}

    def device_status(self):
        """The deviceStatusChanged payload (SDK DeviceStatus)."""
        return {'sn': '', 'connectType': 'connected', 'isWearing': True,
                'batteryLevel': self.battery or 0, 'isCharging': False, 'isInCase': False}

    def _storage(self):
        try:
            return json.loads(self.storage_path.read_text())
        except (OSError, ValueError):
            return {}

    async def m_setLocalStorage(self, data):
        store = self._storage()
        store[str(data.get('key', ''))] = str(data.get('value', ''))
        self.storage_path.parent.mkdir(parents=True, exist_ok=True)
        self.storage_path.write_text(json.dumps(store))
        return True

    async def m_getLocalStorage(self, data):
        return self._storage().get(str(data.get('key', '')), '')

    # Phone-only features: answered politely, as Faceclaw does.
    async def m_getAppLocation(self, data):
        return None

    async def m_startAppLocationUpdates(self, data):
        return False

    async def m_stopAppLocationUpdates(self, data):
        return True

    async def m_pickImageFromAlbum(self, data):
        return None

    async def m_captureImageFromCamera(self, data):
        return None

    # ── glasses UI ──
    async def m_createStartUpPageContainer(self, data):
        """-> StartUpPageCreateResult 0 success, 1 invalid, 2 oversize, 3 outOfMemory."""
        problems = validate_page(data)
        if problems:
            self.log(f'[{self.app["package_id"]}] create rejected: {problems}')
            return 1
        if self.page_created:
            # Stock: create is one-shot per launch; a second call fails.
            self.log(f'[{self.app["package_id"]}] second createStartUpPageContainer -> invalid')
            return 1
        magic = self.glasses.next_magic()
        pb = await self._request(build_create_page(magic, data, self.widget_id, self.session_id), magic, 'eh-create')
        code = ack_code(pb, CMD_CREATE_ACK)
        if code is None:
            self.log(f'[{self.app["package_id"]}] create: no ack'
                     + (' (assuming success)' if self.assume_create_ok else ''))
            code = 0 if self.assume_create_ok else 1
        if code == 0:
            self.page, self.page_created = data, True
        return code

    async def m_rebuildPageContainer(self, data):
        if validate_page(data):
            return False
        if not self.page_created:
            return (await self.m_createStartUpPageContainer(data)) == 0
        magic = self.glasses.next_magic()
        pb = await self._request(build_rebuild_page(magic, data), magic, 'eh-rebuild')
        code = ack_code(pb, CMD_REBUILD_ACK)
        ok = code == OK_CODE[CMD_REBUILD_ACK]
        if ok:
            self.page = data
        return ok

    async def m_textContainerUpgrade(self, data):
        magic = self.glasses.next_magic()
        pb = await self._request(build_text_upgrade(magic, data), magic, 'eh-text')
        code = ack_code(pb, CMD_TEXT_ACK)
        if code is None:
            return False
        if self.page:
            for t in self.page.get('textObject') or []:
                if t.get('containerID') == data.get('containerID'):
                    t['content'] = data.get('content', '')
        return code in (0, OK_CODE[CMD_TEXT_ACK])

    def _image_container(self, cid):
        for c in (self.page or {}).get('imageObject') or []:
            if c.get('containerID') == cid:
                return c
        return None

    async def m_updateImageRawData(self, data):
        """-> 0 success, 1 imageException, 2 imageSizeInvalid, 3 sendFailed. EXPERIMENTAL."""
        box = self._image_container(data.get('containerID'))
        if box is None:
            return IMG_SEND_FAILED
        try:
            raw = image_bytes_from_json(data.get('imageData'))
            pixels = image_to_gray4(raw, int(box['width']), int(box['height']))
        except Exception as e:
            self.log(f'[{self.app["package_id"]}] image decode failed: {e!r}')
            return IMG_EXCEPTION
        pixels = eh.encode_bmp_4bpp(pixels, int(box['width']), int(box['height']))  # firmware wants a BMP
        self.image_session += 1
        chunks = [pixels[i:i + IMAGE_FRAGMENT_BYTES] for i in range(0, len(pixels), IMAGE_FRAGMENT_BYTES)]
        for index, chunk in enumerate(chunks):
            magic = self.glasses.next_magic()
            payload = eh.build_image_raw_data(magic, box['containerID'], box.get('containerName', ''),
                                              len(pixels), index, chunk,
                                              map_session_id=self.image_session, compress_mode=0)
            pb = await self._request(payload, magic, 'eh-image')
            if ack_code(pb, CMD_IMAGE_ACK) != OK_CODE[CMD_IMAGE_ACK]:
                return IMG_SEND_FAILED
        return IMG_OK

    async def m_audioControl(self, data):
        if data.get('source', 'glasses') != 'glasses':
            return False                            # no phone microphone here
        enable = bool(data.get('isOpen'))
        if hasattr(self.glasses, 'enable_mic'):
            return bool(await self.glasses.enable_mic(enable))
        magic = self.glasses.next_magic()
        pb = await self._request(eh.build_audio_control(magic, enable), magic, 'eh-audio')
        return pb is not None

    async def m_imuControl(self, data):
        enable = bool(data.get('iMUReportEn', data.get('isOpen')))
        magic = self.glasses.next_magic()
        pb = await self._request(eh.build_imu_control(magic, enable, int(data.get('reportFrq') or 500)),
                                 magic, 'eh-imu')
        return pb is not None

    async def m_shutDownPageContainer(self, data):
        mode = int(data.get('exitMode') or 0)
        magic = self.glasses.next_magic()
        pb = await self._request(build_shutdown(magic, mode), magic, 'eh-shutdown')
        code = ack_code(pb, CMD_SHUTDOWN_ACK)
        ok = code in (0, OK_CODE[CMD_SHUTDOWN_ACK])
        if mode == 0 and self.on_exit is not None:
            self.on_exit('shutdown')
        return ok

    # ── glasses -> page ──
    async def deliver_event(self, event):
        """Forward one decoded glasses event to the page. Returns the pushed data or None."""
        data = sdk_event(event)
        if data is None or self.push is None:
            return None
        await self.push('evenHubEvent', data)
        if event.get('type') == 'sys-event' and event.get('event_type') in EXIT_EVENTS and self.on_exit:
            self.on_exit(event.get('event_name', 'exit'))
        return data


# ═══════════════════════════════════════════════════════════════════════════════════════════
# 9. Web host: serve the app + shim, relay bridge calls
# ═══════════════════════════════════════════════════════════════════════════════════════════
SHIM_JS = r"""(function () {
  if (window.__G2HUB_EVENHUB__) return;
  window.__G2HUB_EVENHUB__ = true;
  var BASE = (window.__G2HUB_BASE__ || '') + '/__evenhub';
  window.__EVEN_HUB_APP_ID__ = __APP_ID__;
  function post(path, body) {
    return fetch(BASE + path, {method: 'POST', headers: {'Content-Type': 'application/json'},
                               body: JSON.stringify(body)}).then(function (r) { return r.json(); });
  }
  window.flutter_inappwebview = window.flutter_inappwebview || {};
  window.flutter_inappwebview.callHandler = function (name) {
    var args = Array.prototype.slice.call(arguments, 1);
    return post('/call', {handler: name, args: args}).then(function (j) {
      if (j.error) throw new Error(j.error);
      return j.result;
    });
  };
  var queue = [];
  function flush() {
    if (typeof window._listenEvenAppMessage !== 'function') { setTimeout(flush, 50); return; }
    while (queue.length) { try { window._listenEvenAppMessage(queue.shift()); } catch (e) { console.error(e); } }
  }
  var after = 0;
  function poll() {
    fetch(BASE + '/poll?after=' + after).then(function (r) { return r.json(); }).then(function (j) {
      if (j.stop) return;
      after = j.last;
      for (var i = 0; i < j.messages.length; i++) queue.push(j.messages[i]);
      flush();
      poll();
    }).catch(function () { setTimeout(poll, 1000); });
  }
  if (typeof window.addEventListener === 'function') {
    window.addEventListener('error', function (e) {
      post('/call', {handler: 'evenHubRuntimeUncaughtException',
                     args: [{message: String(e && e.message), fatal: true}]}).catch(function () {});
    });
  }
  function start() { post('/ready', {}).then(poll, poll); }
  if (typeof document === 'undefined' || document.readyState === 'complete') setTimeout(start, 0);
  else window.addEventListener('load', function () { setTimeout(start, 0); });
})();
"""

class AppHost:
    """Serves one installed app at http://<host>:<port>/ with the shim injected into every HTML
    page, and relays /__evenhub/call to an EvenHubBridge. Host->page messages are queued and
    long-polled (/__evenhub/poll), which works in every browser and in plain Node fetch.
    After the page says it is ready, the host pushes evenAppLaunchSource and
    deviceStatusChanged, like the official app does after the WebView finishes loading.

    The app is untrusted, and so is every other web page open on this PC: the host answers only
    requests whose Host is its own 127.0.0.1/localhost address (no DNS rebinding) and whose
    Origin, when a browser sends one, is its own origin. No CORS headers are sent, so another
    site cannot drive the glasses through it. Node (the offline tests) sends no Origin."""

    def __init__(self, app_dir, entry, bridge, launch_source='glassesMenu', host='127.0.0.1', port=0, log=print):
        self.app_dir = Path(app_dir)
        self.dist = self.app_dir / 'dist' if (self.app_dir / 'dist').is_dir() else self.app_dir
        self.entry = entry
        self.bridge = bridge
        self.bridge.push = self.push
        self.launch_source = launch_source
        self.host, self.port = host, port
        self.log = log
        self.messages = []          # [(seq, msg)]
        self._cond = None
        self._seq = 0
        self._runner = None
        self.ready = None
        self.stopped = False

    @property
    def url(self):
        return f'http://{self.host}:{self.port}/{self.entry}'

    def shim(self):
        return SHIM_JS.replace('__APP_ID__', json.dumps(self.bridge.app.get('package_id', '')))

    async def push(self, method, data):
        self._seq += 1
        self.messages.append((self._seq, {'type': 'listen_even_app_data', 'method': method, 'data': data}))
        del self.messages[:-500]
        async with self._cond:
            self._cond.notify_all()

    async def start(self):
        from aiohttp import web
        self._cond = asyncio.Condition()
        self.ready = asyncio.Event()
        app = web.Application(client_max_size=16 * 1024 * 1024, middlewares=[self._guard])
        app.router.add_get('/__evenhub/shim.js', self._shim)
        app.router.add_post('/__evenhub/call', self._call)
        app.router.add_post('/__evenhub/ready', self._ready)
        app.router.add_get('/__evenhub/poll', self._poll)
        app.router.add_get('/{path:.*}', self._static)
        self._runner = web.AppRunner(app, access_log=None)
        await self._runner.setup()
        site = web.TCPSite(self._runner, self.host, self.port)
        await site.start()
        self.port = site._server.sockets[0].getsockname()[1]
        return self.url

    async def stop(self):
        self.stopped = True
        if self._cond is not None:
            async with self._cond:
                self._cond.notify_all()
        if self._runner is not None:
            await self._runner.cleanup()
            self._runner = None

    def _allowed_hosts(self):
        return {f'127.0.0.1:{self.port}', f'localhost:{self.port}', f'{self.host}:{self.port}'}

    @property
    def _guard(self):
        from aiohttp import web

        @web.middleware
        async def guard(request, handler):
            allowed = self._allowed_hosts()
            if request.host not in allowed:
                return web.json_response({'error': 'forbidden host'}, status=403)
            origin = request.headers.get('Origin')
            if origin is not None and origin.split('://', 1)[-1] not in allowed:
                return web.json_response({'error': 'forbidden origin'}, status=403)
            return await handler(request)
        return guard

    async def _shim(self, request):
        from aiohttp import web
        return web.Response(text=self.shim(), content_type='application/javascript')

    async def _call(self, request):
        from aiohttp import web
        try:
            body = await request.json()
            if not isinstance(body, dict):
                raise ValueError('body must be an object')
            args = body.get('args') or []
            result = await self.bridge.handle(str(body.get('handler', '')), args if isinstance(args, list) else [])
            return web.json_response({'result': result})
        except Exception as e:
            return web.json_response({'error': repr(e)[:300]})

    async def _ready(self, request):
        from aiohttp import web
        if not self.ready.is_set():
            self.ready.set()
            await self.push('evenAppLaunchSource', {'launchSource': self.launch_source})
            await self.push('deviceStatusChanged', self.bridge.device_status())
        return web.json_response({'ok': True})

    async def _poll(self, request):
        from aiohttp import web
        try:
            after = int(request.query.get('after', 0))
        except ValueError:
            after = 0

        def pending():
            return [m for s, m in self.messages if s > after]
        async with self._cond:
            try:
                await asyncio.wait_for(self._cond.wait_for(lambda: pending() or self.stopped), 25)
            except asyncio.TimeoutError:
                pass
        return web.json_response({'messages': pending(), 'last': self._seq, 'stop': self.stopped})

    async def _static(self, request):
        from aiohttp import web
        rel = request.match_info['path'] or self.entry
        target = (self.dist / rel).resolve()
        if not target.is_relative_to(self.dist.resolve()) or not target.is_file():
            raise web.HTTPNotFound()
        if target.suffix.lower() in ('.html', '.htm'):
            html = target.read_text(encoding='utf-8', errors='replace')
            return web.Response(text=inject_shim(html), content_type='text/html')
        return web.FileResponse(target)


def inject_shim(html):
    """Put <script src="/__evenhub/shim.js"> first in <head>, so callHandler exists before any
    app script runs (the official host injects at document start too)."""
    tag = '<script src="/__evenhub/shim.js"></script>'
    m = re.search(r'<head[^>]*>', html, re.I)
    if m:
        return html[:m.end()] + tag + html[m.end():]
    m = re.search(r'<html[^>]*>', html, re.I)
    if m:
        return html[:m.end()] + '<head>' + tag + '</head>' + html[m.end():]
    return tag + html


# ── headless browser ─────────────────────────────────────────────────────────────────────────
def find_chromium():
    """A Chromium/Chrome binary: PATH first, then Playwright's download cache."""
    for name in ('chromium', 'chromium-browser', 'google-chrome', 'google-chrome-stable'):
        path = shutil.which(name)
        if path:
            return path
    cache = Path.home() / '.cache' / 'ms-playwright'
    for pattern in ('chromium-*/chrome-linux*/chrome', 'chromium_headless_shell-*/chrome-headless-shell-linux*/chrome-headless-shell',
                    'chromium_headless_shell-*/chrome-linux*/headless_shell'):
        found = sorted(cache.glob(pattern))
        if found:
            return str(found[-1])
    return None


class Browser:
    """A headless browser process showing one URL. mode: 'auto' (chromium, then firefox),
    'chromium', 'firefox', or 'none' (print the URL; open it yourself).

    The app's page runs ONLY here, never in the hub's Python: a throw-away profile, Chromium's
    own sandbox (it is only turned off when running as root, which Chromium requires), no
    extensions. network=False (apps without the 'network' permission) points every non-loopback
    request at a dead proxy, so the page can reach its own host but not the internet or the LAN
    (best effort: a manifest whitelist is not enforced host by host)."""

    def __init__(self, url, mode='auto', log=print, network=True):
        self.url, self.mode, self.log = url, mode, log
        self.network = network
        self.proc = None
        self.profile = None
        self.binary = None

    @property
    def alive(self):
        return self.proc is not None and self.proc.returncode is None

    async def start(self):
        mode = self.mode
        chrome = find_chromium() if mode in ('auto', 'chromium') else None
        firefox = shutil.which('firefox') if mode in ('auto', 'firefox') and not chrome else None
        if not chrome and not firefox:
            self.log(f'No headless browser found: open {self.url} yourself.')
            return None
        self.profile = tempfile.mkdtemp(prefix='g2hub-evenhub-')
        if chrome:
            args = [chrome, '--headless=new', '--no-first-run', '--no-default-browser-check',
                    '--disable-gpu', '--disable-background-timer-throttling',
                    '--disable-renderer-backgrounding', '--disable-extensions', '--disable-sync',
                    '--disable-default-apps', '--mute-audio', '--deny-permission-prompts',
                    f'--user-data-dir={self.profile}']
            if not self.network:
                args += ['--proxy-server=http://127.0.0.1:9', '--proxy-bypass-list=127.0.0.1;localhost',
                         '--force-webrtc-ip-handling-policy=disable_non_proxied_udp']
            args.append(self.url)
            if os.geteuid() == 0:
                args.insert(1, '--no-sandbox')
        else:
            args = [firefox, '--headless', '--no-remote', '--profile', self.profile, self.url]
        self.binary = os.path.basename(args[0])
        self.proc = await asyncio.create_subprocess_exec(*args, stdout=asyncio.subprocess.DEVNULL,
                                                         stderr=asyncio.subprocess.DEVNULL,
                                                         start_new_session=True)
        self.log(f'browser: {self.binary} pid {self.proc.pid} -> {self.url}'
                 + ('' if self.network else ' (network blocked)'))
        return self.proc

    async def stop(self, timeout=3.0):
        try:
            if self.proc and self.proc.returncode is None:
                _kill_group(self.proc.pid, 15)
                try:
                    await asyncio.wait_for(self.proc.wait(), timeout)
                except asyncio.TimeoutError:
                    _kill_group(self.proc.pid, 9)
                    await asyncio.wait_for(self.proc.wait(), timeout)
        finally:
            if self.profile:
                shutil.rmtree(self.profile, ignore_errors=True)
                self.profile = None


def _kill_group(pid, sig):
    """Signal the browser and its helper processes (it runs in its own session/process group)."""
    try:
        os.killpg(pid, sig)
    except (ProcessLookupError, PermissionError):
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            pass


# ═══════════════════════════════════════════════════════════════════════════════════════════
# 10. Runtime: registry + menu + launch on cmd 17
# ═══════════════════════════════════════════════════════════════════════════════════════════
class EvenHubRuntime:
    """Ties it together for one glasses connection.

        rt = EvenHubRuntime(session, AppRegistry())
        await rt.register_menu()                    # SID 0x03: built-ins + installed apps
        session.on_device_event = rt.on_device_event
        # picking the app on the glasses sends cmd 17 -> rt launches it headless

    Only one app runs at a time (the glasses show one EvenHub page).
    spawn(coro, name): how background work is started (default: loop.create_task); the hub
    passes its supervisor so the work belongs to the connection and dies with it.
    on_call(app, method, data, result): called after every SDK bridge call (the hub's UI log)."""

    def __init__(self, glasses, registry, builtin_ids=None, browser='auto', host='127.0.0.1',
                 send_session_id=False, log=print, spawn=None, on_call=None):
        self.glasses = glasses
        self.registry = registry
        self.builtin_ids = list(builtin_ids or DEFAULT_BUILTINS)
        self.browser_mode = browser
        self.host = host
        self.send_session_id = send_session_id
        self.log = log
        self.spawn = spawn
        self.on_call = on_call
        self.current = None             # dict(app, bridge, host, browser)
        self._session_counter = 0
        self._tasks = set()
        self.exited = asyncio.Event()

    def _spawn(self, coro, name):
        if self.spawn is not None:
            return self.spawn(coro, name)
        task = asyncio.get_running_loop().create_task(coro, name=name)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        return task

    def menu_apps(self):
        return [a for a in self.registry.list() if a.get('in_menu', True)]

    async def register_menu(self, timeout_s=4.0):
        """Push built-ins + installed apps to the glasses menu. Returns the reply protobuf (None
        = no ack). There is room for 10 - len(builtin_ids) apps."""
        apps = self.menu_apps()[:g2menu.MENU_MAX_ITEMS - len(self.builtin_ids)]
        magic = self.glasses.next_magic()
        payload = build_menu_push(magic, self.builtin_ids, apps)
        self.log(f'menu push: builtins {self.builtin_ids} + '
                 f'{[(a["menu_name"], a["app_id"]) for a in apps]}  pb={payload.hex()}')
        return await self.glasses.request(SID_MENU, payload, magic, label='menu-push', timeout_s=timeout_s)

    async def restore_menu(self, timeout_s=4.0):
        magic = self.glasses.next_magic()
        payload = g2menu.build_builtin_menu_push(magic, self.builtin_ids)
        return await self.glasses.request(SID_MENU, payload, magic, label='menu-restore', timeout_s=timeout_s)

    def on_device_event(self, event):
        """Sync callback for GlassesSession.on_device_event (runs in the BLE callback)."""
        self._spawn(self.handle_event(event), 'evenhub-event')

    async def handle_event(self, event):
        if event.get('type') == 'menu-startup':
            wid = event.get('widget_id', 0)
            app = self.registry.get(int(wid))
            self.log(f'menu-startup widgetId={wid} -> {app["package_id"] if app else "unknown"}')
            if app is None:
                magic = self.glasses.next_magic()
                await self.glasses.request(SID_EVENHUB, build_menu_startup_failed(magic), magic,
                                           label='menu-startup-failed', timeout_s=1.0)
                return
            await self.launch(app['package_id'], launch_source='glassesMenu', widget_id=wid)
            return
        if self.current is not None:
            await self.current['bridge'].deliver_event(event)

    async def launch(self, key, launch_source='glassesMenu', widget_id=None, browser=None):
        """Start the app (package_id or app_id): web host + headless browser. Returns the host URL."""
        app = self.registry.get(key)
        if app is None:
            raise KeyError(f'not installed: {key}')
        await self.stop()
        self.exited.clear()
        self._session_counter += 1
        on_call = None
        if self.on_call is not None:
            on_call = lambda m, d, r, _a=app: self.on_call(_a, m, d, r)  # noqa: E731
        bridge = EvenHubBridge(app, self.glasses, self.registry.storage_dir,
                               widget_id=widget_id if widget_id is not None else app['app_id'],
                               session_id=self._session_counter if self.send_session_id else None,
                               log=self.log, on_exit=self._on_exit, on_call=on_call)
        host = AppHost(self.registry.app_dir(app['package_id']), app['entrypoint'], bridge,
                       launch_source=launch_source, host=self.host, log=self.log)
        url = await host.start()
        browser_obj = Browser(url, browser or self.browser_mode, log=self.log,
                              network=has_network_permission(app))
        self.current = {'app': app, 'bridge': bridge, 'host': host, 'browser': browser_obj,
                        'started_at': time.time(), 'launch_source': launch_source}
        try:
            await browser_obj.start()
        except BaseException:
            await self.stop()
            raise
        self.log(f'launched {app["package_id"]} (widgetId {bridge.widget_id}) at {url}')
        return url

    def _on_exit(self, reason):
        self.log(f'app exit: {reason}')
        self._spawn(self.stop(), 'evenhub-exit')

    async def stop(self, close_page=False):
        """Stop the running app (browser + web host). close_page=True first asks the glasses to
        close its page (shutDownPageContainer exitMode 0, UNTESTED live)."""
        cur, self.current = self.current, None
        if cur is None:
            return False
        try:
            if close_page and cur['bridge'].page_created:
                try:
                    magic = self.glasses.next_magic()
                    await self.glasses.request(SID_EVENHUB, build_shutdown(magic, 0), magic,
                                               label='eh-shutdown', timeout_s=2.0)
                except Exception as e:
                    self.log(f'close page failed: {e!r}')
        finally:
            try:
                await cur['browser'].stop()
            finally:
                await cur['host'].stop()
                self.exited.set()
        return True

    def status(self):
        """What the UI shows: the running app (if any), its page state and the browser process."""
        cur = self.current
        if cur is None:
            return {'running': False}
        b, h, br = cur['browser'], cur['host'], cur['bridge']
        return {'running': True, 'package_id': cur['app']['package_id'], 'app_id': cur['app']['app_id'],
                'name': cur['app'].get('name', ''), 'widget_id': br.widget_id, 'url': h.url,
                'ready': bool(h.ready and h.ready.is_set()), 'page_created': br.page_created,
                'launch_source': cur.get('launch_source'), 'started_at': int(cur.get('started_at', 0)),
                'browser': {'binary': b.binary, 'pid': b.proc.pid if b.proc else None, 'alive': b.alive,
                            'network': b.network}}


# ═══════════════════════════════════════════════════════════════════════════════════════════
# 11. Store (public, unauthenticated endpoints only)
# ═══════════════════════════════════════════════════════════════════════════════════════════
STORE_LANDING_URL = 'https://hub.evenrealities.com/api/v1/apps/landing?package_id={}'
STORE_PUBLIC_CDN = 'https://cdn-pub.evenhub.evenrealities.com'


def store_landing(package_id, timeout=15):
    """Public store card for a released app: {name, icon, foreground[], background,
    creator_name, tagline} or None. The endpoint the hub.evenrealities.com landing page calls
    with skipAuthHeader. The package itself is NOT public: /v2/evenhub/app/download on
    api.evenrealities.com needs a signed request and an Even account token."""
    import urllib.parse
    import urllib.request
    url = STORE_LANDING_URL.format(urllib.parse.quote(package_id))
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        body = json.loads(resp.read().decode('utf-8'))
    return body.get('data') if body.get('code') == 0 else None


def store_asset_url(path):
    """Public CDN URL of a store asset path such as 'prod/<pkg>/icons/..svg'."""
    return f'{STORE_PUBLIC_CDN}/{path.lstrip("/")}'
