"""The hub's web UI: real, editable files in hub/web/static/ (index.html, style.css, theme.js, app.js).

index.html is served at / by hub.routes.core with the API token injected into
<meta name="g2hub-token"> (placeholder TOKEN_PLACEHOLDER) and the asset cache-bust {{G2HUB_VER}}.
Files are read at request time so edits show on reload. Plain files: write JS/CSS normally (no
Python string escaping). tests/test_hub_web.py runs `node --check` on static/*.js.

Layout: every feature is a <section class="card"> in #cards, moved into place by buildShell():
    data-sec     the section it belongs to (home, dashboard, apps, glasses, settings, developer, log;
                 SECTIONS in app.js, developer + log only in Developer mode)
    data-page    optional sub-page of that section (PAGES in app.js, e.g. apps/translate); the
                 section's landing page shows a tile for each sub-page
    data-col     0 / 1 (left / right column), full (whole width, after the columns) or top (first)
    data-status  confirmed | ack | exp | hub -- the evidence level from docs/status.md; the badge
                 is shown in Developer mode, and "exp" cards also get a Beta pill for everyone
    data-icon    icon key from ICO in app.js;  data-beta  hidden unless Beta features are on
Elements with class dev-only appear only in Developer mode (Settings → Beta and developer).
Buttons that only work with the glasses connected carry data-needs="glasses" (a <fieldset> with
it disables everything inside); renderConn() disables them while the glasses are offline.
Any element with data-go="section[/page]" navigates there.

Security: the token is in a <meta> tag, sent back in X-G2Hub-Token (see hub.auth). Every dynamic
string goes through escapeHtml(); rows built from data never use inline handlers with data.
NAV_DIRECTIONS / MENU_APPS at the top of app.js mirror g2.navigation.DIRECTION and
g2.menu.BUILTIN_MENU_APPS (checked by tests/test_hub_web.py).
"""
from pathlib import Path

STATIC_DIR = Path(__file__).resolve().parent / 'static'
TOKEN_PLACEHOLDER = '{{G2HUB_TOKEN}}'
VERSION_PLACEHOLDER = '{{G2HUB_VER}}'
ASSET_TYPES = {
    'app.js': 'application/javascript',
    'theme.js': 'application/javascript',
    'style.css': 'text/css',
}


def read_static(name):
    return (STATIC_DIR / name).read_text(encoding='utf-8')


def render_index(token, version):
    return (read_static('index.html')
            .replace(TOKEN_PLACEHOLDER, token or '', 1)
            .replace(VERSION_PLACEHOLDER, version))


def __getattr__(name):          # PAGE: raw index.html + css + js, for tests / tooling
    if name == 'PAGE':
        return '\n'.join(read_static(n) for n in ('index.html', 'style.css', 'theme.js', 'app.js'))
    raise AttributeError(name)
