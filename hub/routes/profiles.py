"""Profiles (named widget sets) and their schedule. Logic lives in hub/profiles.py.

GET  /api/profiles           -> {profiles: [{name, sections, saved_at}], active, schedule, connected}
POST /api/profiles           {action: save|apply|delete, name} -> the same body (+ result)
POST /api/profiles/schedule  {enabled, rules: [{profile, start: 'HH:MM', end: 'HH:MM', days?: [0..6]}]}
"""
import asyncio
import datetime

from aiohttp import web

from hub import profiles, state
from hub.events import on_event

SCHEDULER_INTERVAL_S = 60


def _device():
    return state.active_device_id()


def _view(**extra):
    dev = _device()
    return {'profiles': profiles.list_profiles(dev), 'active': profiles.active_profile(dev),
            'schedule': profiles.get_schedule(dev), 'connected': state.current_session() is not None, **extra}


async def api_profiles_get(request):
    if _device() is None:
        return web.json_response({'error': 'no active glasses'}, status=503)
    return web.json_response(_view())


async def api_profiles_post(request):
    dev = _device()
    if dev is None:
        return web.json_response({'error': 'no active glasses'}, status=503)
    try:
        data = await request.json()
    except ValueError:
        return web.json_response({'error': 'invalid JSON'}, status=400)
    action = data.get('action') if isinstance(data, dict) else None
    try:
        if action == 'save':
            result = profiles.save_profile(dev, data.get('name'))
        elif action == 'apply':
            name = profiles.clean_name(data.get('name'))
            result = profiles.apply_profile(dev, name)
        elif action == 'delete':
            name = profiles.clean_name(data.get('name'))
            if not profiles.delete_profile(dev, name):
                return web.json_response({'error': f'no profile named {name!r}'}, status=404)
            result = {'name': name, 'deleted': True}
        else:
            return web.json_response({'error': 'action must be save, apply or delete'}, status=400)
    except profiles.ProfileError as e:
        return web.json_response({'error': str(e)}, status=400)
    except KeyError as e:
        return web.json_response({'error': f'no profile named {e.args[0]!r}'}, status=404)
    return web.json_response(_view(result=result))


async def api_profiles_schedule(request):
    dev = _device()
    if dev is None:
        return web.json_response({'error': 'no active glasses'}, status=503)
    try:
        data = await request.json()
        if not isinstance(data, dict):
            raise profiles.ProfileError('JSON object required')
        profiles.set_schedule(dev, data.get('enabled', False), data.get('rules', []))
    except (profiles.ProfileError, ValueError) as e:
        return web.json_response({'error': str(e)}, status=400)
    return web.json_response(_view())


async def profile_scheduler_loop(now_fn=datetime.datetime.now):
    """Background task: every minute compare the schedule with the local clock and switch profile
    when the scheduled target changes. Never raises (a bad tick is logged and retried)."""
    while True:
        await asyncio.sleep(SCHEDULER_INTERVAL_S)
        try:
            dev = _device()
            if dev is not None:
                profiles.schedule_tick(dev, now_fn())   # quick; must run on the loop (spawns the push)
        except asyncio.CancelledError:
            raise
        except Exception as e:
            on_event(f'Profile scheduler error: {e}', level='warn')


ROUTES = [
    ('GET', '/api/profiles', api_profiles_get),
    ('POST', '/api/profiles', api_profiles_post),
    ('POST', '/api/profiles/schedule', api_profiles_schedule),
]
