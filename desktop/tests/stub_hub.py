"""Fake G2 hub for testing the desktop app without glasses (no BLE, nothing real).

    python desktop/tests/stub_hub.py 18766 [--fail] [--disconnected]

Implements the endpoints the desktop app uses, with the same local-only checks as the real hub.
Every POST is appended to $STUB_LOG (JSON lines) so tests can assert what was sent.
With $STUB_TOKEN set, POSTs must carry that value in X-G2Hub-Token (like hub/auth.py).
"""
import argparse
import json
import os
import sys

from aiohttp import web

ap = argparse.ArgumentParser()
ap.add_argument('port', type=int)
ap.add_argument('--fail', action='store_true', help='exit immediately with an error')
ap.add_argument('--disconnected', action='store_true')
ap.add_argument('--reconnecting', action='store_true', help='report a resume-reconnect in /api/status')
ap.add_argument('--link', help='value of "link" in /api/status while not connected (e.g. paused, disabled)')
args = ap.parse_args()
if args.fail:
    print('stub hub: simulated start-up failure (no Bluetooth adapter)', flush=True)
    sys.exit(3)

allowed = {f'localhost:{args.port}', f'127.0.0.1:{args.port}'}
TOKEN = os.environ.get('STUB_TOKEN')
STATE = {'connected': not (args.disconnected or args.reconnecting or args.link), 'active': 1,
         'devices': [{'id': 1, 'pair_id': 'AB12', 'name': 'Work G2', 'right_mac': None, 'left_mac': None,
                      'firmware': '1.0', 'last_seen': 0, 'is_default': 1},
                     {'id': 2, 'pair_id': 'CD34', 'name': 'Spare G2', 'right_mac': None, 'left_mac': None,
                      'firmware': '1.0', 'last_seen': 0, 'is_default': 0}]}


def record(path, body):
    if os.environ.get('STUB_LOG'):
        with open(os.environ['STUB_LOG'], 'a') as f:
            f.write(json.dumps({'path': path, 'body': body}) + '\n')


@web.middleware
async def local_only(request, handler):
    if request.host not in allowed:
        return web.json_response({'error': 'forbidden host'}, status=403)
    origin = request.headers.get('Origin')
    if origin and origin.split('://', 1)[-1] not in allowed:
        return web.json_response({'error': 'forbidden origin'}, status=403)
    if request.method not in ('GET', 'HEAD') and request.content_type != 'application/json':
        return web.json_response({'error': 'JSON body required'}, status=415)
    if TOKEN and request.method not in ('GET', 'HEAD') and request.headers.get('X-G2Hub-Token') != TOKEN:
        return web.json_response({'error': 'missing or wrong API token'}, status=401)
    return await handler(request)


async def index(r):
    record('GET /', {'ua': r.headers.get('User-Agent', '')[:60]})
    return web.Response(text='<!doctype html><title>Stub hub</title><h1>Stub G2 hub</h1>'
                        '<p id=s>...</p><script>fetch("/api/devices").then(r=>r.json()).then(j=>'
                        'document.getElementById("s").textContent=JSON.stringify(j))</script>',
                        content_type='text/html')


async def status(r):
    # Same shape as hub/routes/core.py api_status: {connected, link, paused}.
    link = ('connected' if STATE['connected'] else args.link or ('reconnecting' if args.reconnecting else 'searching'))
    return web.json_response({'connected': STATE['connected'], 'link': link,
                              'paused': ['adapter'] if link == 'paused' else []})


async def devices(r):
    return web.json_response({'devices': STATE['devices'], 'active': STATE['active'],
                              'connected': STATE['connected']})


async def settings(r):
    return web.json_response({'saved': {}, 'status': {'battery': 77, 'charging': False, 'worn': True,
                                                      'case_battery': 55} if STATE['connected'] else {}})


async def scan(r):
    body = await r.json()
    record('/api/devices/scan', body)
    return web.json_response({'found': [{'pair_id': 'AB12', 'known_id': 1}, {'pair_id': 'EF56', 'known_id': None}]})


async def select(r):
    body = await r.json()
    record('/api/devices/select', body)
    STATE['active'] = int(body.get('id', 0))
    return web.json_response({'ok': True})


async def notify(r):
    body = await r.json()
    record('/api/notify_send', body)
    if not STATE['connected']:
        return web.json_response({'error': 'not connected'}, status=503)
    return web.json_response({'ok': True, 'result': 'stub'})


app = web.Application(middlewares=[local_only])
app.router.add_get('/', index)
app.router.add_get('/api/status', status)
app.router.add_get('/api/devices', devices)
app.router.add_get('/api/settings', settings)
app.router.add_post('/api/devices/scan', scan)
app.router.add_post('/api/devices/select', select)
app.router.add_post('/api/notify_send', notify)
print(f'stub hub on 127.0.0.1:{args.port}', flush=True)
web.run_app(app, host='127.0.0.1', port=args.port, print=None)
