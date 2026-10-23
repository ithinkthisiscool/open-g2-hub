"""The glasses' app menu (SID 0x03 menu push; REPLACES the whole menu).

Every menu push goes through push_menu(): the Menu card, the profile restore on connect and the
EvenHub apps card. The menu holds the built-in apps (itemType 0, saved in the per-pair 'menu'
section) followed by installed EvenHub apps (itemType 1, saved per pair by package id in the
'evenhub_menu' section, see Store.evenhub_menu). Editing the built-ins keeps the EvenHub items,
and the restore on connect re-sends both.
"""
from aiohttp import web

from g2 import evenhub as eh
from g2 import menu as rmp
from hub import evenhub_runtime as rt
from hub import state, sync
from hub.events import notify_state_changed, on_event


def evenhub_registry():
    """The installed EvenHub apps (<data dir>/evenhub, shared by every pair)."""
    return rt.AppRegistry()


def saved_builtins():
    """Built-in ids of this pair's saved menu, or None when none was saved yet."""
    items = (state.load_hub_state().get('menu') or {}).get('items')
    if not items:
        return None
    ids = [int(i.get('appId') or 0) for i in items if isinstance(i, dict)]
    return [i for i in ids if i in rmp.BUILTIN_MENU_APPS] or None


def saved_evenhub(registry=None):
    """Registry entries of the EvenHub apps in this pair's menu (installed ones only), in order."""
    dev = state.active_device_id()
    if dev is None:
        return []
    registry = registry or evenhub_registry()
    out = []
    for pid in state.STORE.evenhub_menu(dev):
        entry = registry.get(pid)
        if entry is not None:
            out.append(entry)
    return out


def check_menu(builtin_ids, apps):
    """None when built-ins + apps make a valid menu, else the error text."""
    if len(set(builtin_ids)) != len(builtin_ids):
        return 'duplicate app in menu'
    n = len(builtin_ids) + len(apps)
    if not rmp.MENU_MIN_ITEMS <= n <= rmp.MENU_MAX_ITEMS:
        extra = f' ({len(builtin_ids)} built-in + {len(apps)} EvenHub)' if apps else ''
        return f'menu needs {rmp.MENU_MIN_ITEMS}-{rmp.MENU_MAX_ITEMS} items (got {n}{extra})'
    return None


async def push_menu(items_in, evenhub=None, save=True):
    """Validate and push a menu. Returns (http_status, body).

    items_in: [{appId}, ...] -- built-in ids, in order. An installed EvenHub app's app_id is also
              accepted (it is added to the EvenHub items).
    evenhub:  package ids of the EvenHub apps to show after the built-ins; None = the ones saved
              for this pair. On success both lists are saved for this pair (save=False: the
              sync engine, which pushes what is already saved)."""
    session = state.current_session()
    if session is None:
        return 503, {'error': 'not connected'}
    registry = evenhub_registry()
    installed = {a['app_id']: a for a in registry.list()}
    ids = [int(i.get('appId') or 0) for i in items_in]
    bad = [i for i in ids if i not in rmp.BUILTIN_MENU_APPS and i not in installed]
    if bad:
        return 400, {'error': f'not a menu app: {bad}'}
    builtins = [i for i in ids if i in rmp.BUILTIN_MENU_APPS]
    if evenhub is None:
        apps = saved_evenhub(registry)
    else:
        apps = [registry.get(p) for p in evenhub]
        apps = [a for a in apps if a is not None]
    for i in ids:
        if i not in rmp.BUILTIN_MENU_APPS and all(a['app_id'] != i for a in apps):
            apps.append(installed[i])
    err = check_menu(builtins, apps)
    if err:
        return 400, {'error': err}
    items = [{'name': rmp.BUILTIN_MENU_APPS[i], 'appId': i} for i in builtins]
    names = [i['name'] for i in items] + [f'{a["menu_name"]} (EvenHub {a["app_id"]})' for a in apps]
    on_event(f'menu push (REPLACES menu): {names}', level='warn')
    magic = session.next_magic()
    if apps:
        # Plugin items {itemType 1, iconNum 1, name, itemAppId}: the form the official app builds
        # after an install (UNTESTED live, docs/research/evenhub_apps_install.md section 5).
        payload = rt.build_menu_push(magic, builtins, apps)
    else:
        # Built-ins carry only itemType=0 + itemAppId, exactly like the official app.
        payload = rmp.build_builtin_menu_push(magic, builtins)
    raw = await session._send_and_get_payload(rmp.SID_MENU, eh.FLAG_REQUEST, magic, payload,
                                               session.next_seq(), 'menu push', timeout_s=4.0)
    if raw is None:
        on_event('menu result: no ack', level='warn')
        return 504, {'error': 'no ack from glasses'}
    on_event(f'menu result: {raw.hex()}', level='ok')
    if save:
        state.save_hub_state('menu', {'items': items})
        dev = state.active_device_id()
        if dev is not None:
            state.STORE.set_evenhub_menu(dev, [a['package_id'] for a in apps])
    return 200, {'result': raw.hex(), 'evenhub': [a['package_id'] for a in apps]}


async def api_push_menu(request):
    """Legacy direct push (scripts, tests): push now, save on success. The web UI uses /api/menu."""
    if state.current_session() is None:
        return web.json_response({'error': 'not connected'}, status=503)
    data = await request.json()
    async with sync.ENGINE.exclusive():
        status, body = await push_menu(data.get('items', []))
    return web.json_response(body, status=status)


async def api_menu(request):
    """POST {items: [{appId}, ...], wait?} -> validate the built-in part of this pair's menu (the
    saved EvenHub apps follow it), save it, and let the sync engine push it."""
    data = await request.json()
    if not isinstance(data, dict) or not isinstance(data.get('items'), list):
        return web.json_response({'error': 'items must be a list'}, status=400)
    try:
        ids = [int(i.get('appId') or 0) if isinstance(i, dict) else int(i) for i in data['items']]
    except (TypeError, ValueError):
        return web.json_response({'error': 'appId must be a number'}, status=400)
    bad = [i for i in ids if i not in rmp.BUILTIN_MENU_APPS]
    if bad:
        return web.json_response({'error': f'not a menu app: {bad}'}, status=400)
    err = check_menu(ids, saved_evenhub())
    if err:
        return web.json_response({'error': err}, status=400)
    state.save_hub_state('menu', {'items': [{'name': rmp.BUILTIN_MENU_APPS[i], 'appId': i} for i in ids]})
    notify_state_changed('menu')
    out = await sync.save_and_sync('menu', bool(data.get('wait', False)))
    body = {'items': ids, 'sync': sync.status('menu')}
    if out is not None:
        body.update(ok=out.ok, result=out.message)
    return web.json_response(body)


ROUTES = [
    ('POST', '/api/push_menu', api_push_menu),
    ('POST', '/api/menu', api_menu),
]
