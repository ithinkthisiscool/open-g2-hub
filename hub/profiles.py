"""Profiles: named widget sets ("Work", "Home") per pair of glasses, plus time-based switching.

A profile is a snapshot of the pair's saved widget configuration:

    {'sections': {'weather': {...}, 'calendar': {...}, 'quicklist': {...}, 'menu': {...},
                  'news': {...}, ...}, 'saved_at': <unix ts>}

Stored through Store.profiles()/set_profiles() in the hidden '_profiles' config section (no
schema change, so an existing hub.db keeps working untouched). Applying a profile writes those
sections back as the pair's current configuration and marks them dirty in the sync engine
(hub/sync.py): pushed at once when this pair is connected, queued for the next connect otherwise.

Schedule: {'enabled': False, 'rules': [{'profile', 'start': 'HH:MM', 'end': 'HH:MM', 'days'?: [0..6]}]}
with Monday=0. A window with end <= start wraps past midnight; `days` names the day the window
STARTS. The first matching rule wins. The scheduler only acts when the scheduled target changes,
so a manual apply is not undone a minute later.
"""
import time

from hub import state, sync
from hub.events import notify_state_changed, on_event

# Config sections a profile captures. 'quicklist' is the Tasks widget. Deliberately excluded:
# even_ai (API keys / assistant config), watchface (per-upload bookkeeping), underscore sections.
PROFILE_SECTIONS = ('weather', 'calendar', 'quicklist', 'menu', 'evenhub_menu', 'news', 'stocks', 'health',
                    'settings')
MAX_NAME_LEN = 40


class ProfileError(ValueError):
    pass


def clean_name(name):
    name = ' '.join(str(name or '').split())
    if not name:
        raise ProfileError('name required')
    if len(name) > MAX_NAME_LEN:
        raise ProfileError(f'name too long (max {MAX_NAME_LEN})')
    return name


def _store():
    return state.STORE


def list_profiles(device):
    """[{name, sections: [section names], saved_at}] sorted by name, plus nothing else."""
    profs = _store().profiles(device)['profiles']
    return [{'name': n, 'sections': sorted(p.get('sections', {})), 'saved_at': p.get('saved_at')}
            for n, p in sorted(profs.items(), key=lambda kv: kv[0].lower())]


def active_profile(device):
    return _store().profiles(device)['active']


def save_profile(device, name):
    """Snapshot the pair's current widget configuration under `name` (overwrites a same-named
    profile) and mark it active. Returns the profile summary."""
    name = clean_name(name)
    st = _store()
    config = st.all_config(device)
    sections = {k: config[k] for k in PROFILE_SECTIONS if k in config}
    data = st.profiles(device)
    data['profiles'][name] = {'sections': sections, 'saved_at': int(time.time())}
    st.set_profiles(device, data['profiles'], name)
    return {'name': name, 'sections': sorted(sections), 'saved_at': data['profiles'][name]['saved_at']}


def delete_profile(device, name):
    """Remove a profile. Returns True if it existed. Scheduled rules naming it simply never match
    a profile and are skipped."""
    st = _store()
    data = st.profiles(device)
    if name not in data['profiles']:
        return False
    del data['profiles'][name]
    active = None if data['active'] == name else data['active']
    st.set_profiles(device, data['profiles'], active)
    return True


def apply_profile(device, name, push=True):
    """Write the profile's sections back as the pair's current configuration and make it active.
    With `push` (and this pair active) the changed sections are marked dirty in the sync engine,
    which pushes them now when connected or on the next connect. Returns {name, sections,
    pushed} (pushed: the glasses are connected, so the push is under way)."""
    st = _store()
    data = st.profiles(device)
    prof = data['profiles'].get(name)
    if prof is None:
        raise KeyError(name)
    sections = prof.get('sections', {})
    for section, cfg in sections.items():
        st.set(device, section, cfg)
    st.set_profiles(device, data['profiles'], name)
    pushed = False
    if push and device == state.active_device_id():
        sync.mark(*sections, now=True)
        pushed = state.current_session() is not None
    on_event(f'Profile "{name}" applied ({", ".join(sorted(sections)) or "no sections"}); '
             + ('pushing to the glasses' if pushed else 'saved for the next connect'), level='ok')
    for section in sections:
        notify_state_changed(section)
    notify_state_changed('profiles')
    return {'name': name, 'sections': sorted(sections), 'pushed': pushed}


# ── schedule ────────────────────────────────────────────────────────────────────────────────
def _minutes(hhmm):
    try:
        h, m = str(hhmm).split(':')
        h, m = int(h), int(m)
    except (ValueError, TypeError):
        raise ProfileError(f'bad time {hhmm!r} (use HH:MM)')
    if not (0 <= h <= 23 and 0 <= m <= 59):
        raise ProfileError(f'bad time {hhmm!r} (use HH:MM)')
    return h * 60 + m


def normalize_rules(rules):
    """Validate and clean schedule rules; raises ProfileError."""
    if not isinstance(rules, list):
        raise ProfileError('rules must be a list')
    out = []
    for r in rules:
        if not isinstance(r, dict):
            raise ProfileError('each rule must be an object')
        rule = {'profile': clean_name(r.get('profile')),
                'start': f'{_minutes(r.get("start")) // 60:02d}:{_minutes(r.get("start")) % 60:02d}',
                'end': f'{_minutes(r.get("end")) // 60:02d}:{_minutes(r.get("end")) % 60:02d}'}
        if rule['start'] == rule['end']:
            raise ProfileError('start and end must differ')
        days = r.get('days')
        if days:
            if not isinstance(days, list) or not all(isinstance(d, int) and not isinstance(d, bool)
                                                     and 0 <= d <= 6 for d in days):
                raise ProfileError('days must be a list of 0 (Mon) .. 6 (Sun)')
            rule['days'] = sorted(set(days))
        out.append(rule)
    return out


def scheduled_profile(rules, now, known=None):
    """The profile the rules select at `now` (a datetime / struct with weekday(), hour, minute),
    or None. First matching rule wins; rules naming a profile not in `known` (when given) are skipped."""
    cur = now.hour * 60 + now.minute
    today = now.weekday()
    for r in rules:
        if known is not None and r.get('profile') not in known:
            continue
        start, end = _minutes(r['start']), _minutes(r['end'])
        days = r.get('days') or range(7)
        if start < end:
            hit = start <= cur < end and today in days
        else:                                   # wraps past midnight; `days` = the day it starts
            hit = (cur >= start and today in days) or (cur < end and (today - 1) % 7 in days)
        if hit:
            return r['profile']
    return None


def get_schedule(device):
    s = _store().profile_schedule(device)
    return {'enabled': s['enabled'], 'rules': s['rules']}


def set_schedule(device, enabled, rules):
    rules = normalize_rules(rules)
    cur = _store().profile_schedule(device)
    _store().set_profile_schedule(device, {'enabled': bool(enabled), 'rules': rules,
                                           'last_target': cur['last_target'] if enabled else None})
    return {'enabled': bool(enabled), 'rules': rules}


def schedule_tick(device, now):
    """One scheduler evaluation. Applies the scheduled profile if the target changed since the
    last tick. Returns the applied result dict, or None."""
    st = _store()
    sched = st.profile_schedule(device)
    if not sched['enabled']:
        return None
    known = st.profiles(device)['profiles']
    target = scheduled_profile(sched['rules'], now, known)
    if target == sched['last_target']:
        return None
    st.set_profile_schedule(device, {**sched, 'last_target': target})
    if target is None or target == st.profiles(device)['active']:
        return None
    on_event(f'Schedule: switching to profile "{target}"', level='info')
    return apply_profile(device, target)
