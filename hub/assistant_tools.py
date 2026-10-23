"""Tools that let Claude (Even AI "Claude" mode) see and control the glasses through the hub.

"Read me the second news article", "add buy milk to my list", "what's on my calendar",
"set brightness to 30", "remind me about the dentist tomorrow at 3" — Claude answers these by
calling the tools below. Each tool goes through the same code path as the hub's web UI (the
hub's own HTTP API or its helper functions), so what Claude changes is saved per pair of glasses
and shows up in the web page.

The hub builds a `Hub` object with the functions this module needs (to avoid importing the hub
itself) and passes `AssistantTools(hub).run` to ClaudeResponder.ask().
"""
import time

TOOLS = [
    {'name': 'list_news', 'description': 'List the news articles currently on the glasses news widget (number, source, title).',
     'input_schema': {'type': 'object', 'properties': {}}},
    {'name': 'read_news_article', 'description': 'Get the full text of one news article from the widget so you can read it to the user.',
     'input_schema': {'type': 'object', 'properties': {'number': {'type': 'integer', 'description': '1-based article number from list_news'}},
                      'required': ['number']}},
    {'name': 'refresh_news', 'description': 'Fetch fresh stories and push them to the news widget.',
     'input_schema': {'type': 'object', 'properties': {}}},
    {'name': 'list_tasks', 'description': "List the tasks on the glasses' task list (quicklist) with done status.",
     'input_schema': {'type': 'object', 'properties': {}}},
    {'name': 'add_task', 'description': 'Add a task to the task list on the glasses.',
     'input_schema': {'type': 'object', 'properties': {'title': {'type': 'string'}}, 'required': ['title']}},
    {'name': 'set_task_done', 'description': 'Mark a task done or not done. Match by its title (partial is fine) or its 1-based number.',
     'input_schema': {'type': 'object', 'properties': {'task': {'type': 'string'}, 'done': {'type': 'boolean'}},
                      'required': ['task', 'done']}},
    {'name': 'remove_task', 'description': 'Delete a task from the list (by title or 1-based number).',
     'input_schema': {'type': 'object', 'properties': {'task': {'type': 'string'}}, 'required': ['task']}},
    {'name': 'list_calendar', 'description': 'List upcoming calendar events shown on the glasses.',
     'input_schema': {'type': 'object', 'properties': {}}},
    {'name': 'add_calendar_event',
     'description': 'Add an event to the glasses calendar. Give start as local "YYYY-MM-DD HH:MM", or minutes_from_now.',
     'input_schema': {'type': 'object', 'properties': {
         'title': {'type': 'string'}, 'start': {'type': 'string', 'description': 'local time YYYY-MM-DD HH:MM'},
         'minutes_from_now': {'type': 'number'}, 'duration_min': {'type': 'number', 'description': 'default 60'},
         'location': {'type': 'string'}, 'all_day': {'type': 'boolean'}}, 'required': ['title']}},
    {'name': 'remove_calendar_event', 'description': 'Delete a calendar event by (partial) title.',
     'input_schema': {'type': 'object', 'properties': {'title': {'type': 'string'}}, 'required': ['title']}},
    {'name': 'get_weather', 'description': 'Current weather where the user is, as shown on the glasses.',
     'input_schema': {'type': 'object', 'properties': {}}},
    {'name': 'get_glasses_status', 'description': 'Battery, charging, worn, charging-case battery, firmware and display settings of the glasses.',
     'input_schema': {'type': 'object', 'properties': {}}},
    {'name': 'set_brightness', 'description': 'Set display brightness 1-50, or auto=true for automatic brightness.',
     'input_schema': {'type': 'object', 'properties': {'level': {'type': 'integer', 'minimum': 1, 'maximum': 50},
                                                       'auto': {'type': 'boolean'}}}},
    {'name': 'set_silent_mode', 'description': 'Turn silent (do not disturb) mode on or off.',
     'input_schema': {'type': 'object', 'properties': {'on': {'type': 'boolean'}}, 'required': ['on']}},
    {'name': 'send_notification', 'description': 'Show a notification on the glasses.',
     'input_schema': {'type': 'object', 'properties': {'title': {'type': 'string'}, 'message': {'type': 'string'}},
                      'required': ['title', 'message']}},
    {'name': 'close_display', 'description': 'Hide the display: close whatever full-screen app (translate, teleprompter, navigation) is open on the glasses, returning to the normal dashboard.',
     'input_schema': {'type': 'object', 'properties': {}}},
    {'name': 'show_dashboard', 'description': 'Go back to the glasses dashboard (closes any open full-screen app).',
     'input_schema': {'type': 'object', 'properties': {}}},
    {'name': 'show_weather', 'description': 'Fetch fresh weather and push it to the glasses dashboard.',
     'input_schema': {'type': 'object', 'properties': {}}},
    {'name': 'adjust_brightness', 'description': 'Change display brightness relative to now (delta in 1-50 units, positive brighter, negative dimmer).',
     'input_schema': {'type': 'object', 'properties': {'delta': {'type': 'integer', 'minimum': -49, 'maximum': 49}},
                      'required': ['delta']}},
]


class AssistantTools:
    def __init__(self, hub):
        """hub: object with attributes
            news_stories() -> list[dict]            refresh_news() -> awaitable
            load_tasks() -> list[dict]              save_tasks(tasks) -> awaitable (push + save)
            calendar_state() -> {events, h24}       set_calendar(events) -> awaitable (save + push)
            weather_now() -> dict|None               glasses_status() -> dict
            post(path, body) -> awaitable (status, json)   (the hub's own API)"""
        self.hub = hub

    async def run(self, name, args):
        fn = getattr(self, f't_{name}', None)
        if fn is None:
            raise ValueError(f'unknown tool {name}')
        return await fn(**args)

    # ── news ────────────────────────────────────────────────────────────────────────────────
    async def t_list_news(self):
        stories = self.hub.news_stories()
        if not stories:
            return 'The news widget is empty.'
        return '\n'.join(f"{i}. [{s.get('source', '')}] {s['title']}" for i, s in enumerate(stories, 1))

    async def t_read_news_article(self, number):
        stories = self.hub.news_stories()
        if not 1 <= int(number) <= len(stories):
            return f'There are {len(stories)} articles; pick 1-{len(stories)}.'
        s = stories[int(number) - 1]
        return f"{s['title']} ({s.get('source', '')})\n\n{s.get('content') or 'No article text available.'}"

    async def t_refresh_news(self):
        await self.hub.refresh_news()
        return 'Fresh stories are being fetched and pushed to the news widget.'

    # ── tasks ───────────────────────────────────────────────────────────────────────────────
    def _find(self, items, key, field='title'):
        key = str(key).strip()
        if key.isdigit() and 1 <= int(key) <= len(items):
            return int(key) - 1
        low = key.lower()
        matches = [i for i, t in enumerate(items) if low in str(t.get(field, '')).lower()]
        if not matches:
            raise ValueError(f'no item matching "{key}"')
        return matches[0]

    async def t_list_tasks(self):
        tasks = self.hub.load_tasks()
        if not tasks:
            return 'The task list is empty.'
        return '\n'.join(f"{i}. [{'x' if t.get('completed') else ' '}] {t['title']}" for i, t in enumerate(tasks, 1))

    async def t_add_task(self, title):
        tasks = self.hub.load_tasks() + [{'title': title.strip()[:120], 'completed': False}]
        await self.hub.save_tasks(tasks)
        return f'Added "{title}". The list now has {len(tasks)} tasks.'

    async def t_set_task_done(self, task, done):
        tasks = self.hub.load_tasks()
        i = self._find(tasks, task)
        tasks[i]['completed'] = bool(done)
        await self.hub.save_tasks(tasks)
        return f'Marked "{tasks[i]["title"]}" as {"done" if done else "not done"}.'

    async def t_remove_task(self, task):
        tasks = self.hub.load_tasks()
        i = self._find(tasks, task)
        removed = tasks.pop(i)
        await self.hub.save_tasks(tasks)
        return f'Removed "{removed["title"]}".'

    # ── calendar ────────────────────────────────────────────────────────────────────────────
    async def t_list_calendar(self):
        events = sorted((e for e in self.hub.calendar_state()['events'] if e['end'] > time.time()),
                        key=lambda e: e['start'])
        if not events:
            return 'No upcoming events.'
        fmt = lambda ts: time.strftime('%a %d %b %H:%M', time.localtime(ts))  # noqa: E731
        return '\n'.join(f"- {e['title']}: {'all day ' + time.strftime('%a %d %b', time.localtime(e['start'])) if e.get('all_day') else fmt(e['start']) + ' to ' + time.strftime('%H:%M', time.localtime(e['end']))}"
                         f"{' at ' + e['location'] if e.get('location') else ''}" for e in events)

    async def t_add_calendar_event(self, title, start=None, minutes_from_now=None, duration_min=60,
                                   location='', all_day=False):
        ev = {'title': title, 'location': location, 'duration_min': duration_min or 60, 'all_day': all_day}
        if start:
            ev['start'] = int(time.mktime(time.strptime(start.strip()[:16], '%Y-%m-%d %H:%M')))
        elif minutes_from_now is not None:
            ev['minutes_from_now'] = minutes_from_now
        else:
            raise ValueError('give start ("YYYY-MM-DD HH:MM") or minutes_from_now')
        if all_day:
            t = time.localtime(ev.get('start', time.time()))
            ev['start'] = int(time.mktime(t[:3] + (0, 0, 0, 0, 0, -1)))
            ev['end'] = ev['start'] + 86340
        await self.hub.set_calendar(self.hub.calendar_state()['events'] + [ev])
        return f'Added "{title}" to the calendar.'

    async def t_remove_calendar_event(self, title):
        events = self.hub.calendar_state()['events']
        i = self._find(events, title)
        removed = events.pop(i)
        await self.hub.set_calendar(events)
        return f'Removed "{removed["title"]}".'

    # ── weather / status / settings / notifications ───────────────────────────────────────
    async def t_get_weather(self):
        w = self.hub.weather_now()
        return w.get('summary') if w else 'Weather has not been fetched yet.'

    async def t_get_glasses_status(self):
        s = self.hub.glasses_status()
        if not s:
            return 'No status yet (glasses may be disconnected).'
        keys = ('battery', 'charging', 'worn', 'case_battery', 'right_version', 'brightness_auto',
                'brightness_level', 'silent_mode', 'head_up', 'head_up_angle', 'wear_detection', 'display_timeout')
        return ', '.join(f'{k}={s[k]}' for k in keys if k in s)

    async def t_set_brightness(self, level=None, auto=None):
        body = {'auto_brightness': bool(auto)} if auto else {'auto_brightness': False, 'brightness': int(level or 25)}
        status, data = await self.hub.post('/api/settings', body)
        if status != 200:
            raise RuntimeError(data.get('error', status))
        return 'Brightness set to automatic.' if auto else f'Brightness set to {body["brightness"]} of 50.'

    async def t_set_silent_mode(self, on):
        status, data = await self.hub.post('/api/settings', {'silent_mode': bool(on)})
        if status != 200:
            raise RuntimeError(data.get('error', status))
        return f'Silent mode {"on" if on else "off"}.'

    async def t_send_notification(self, title, message):
        status, data = await self.hub.post('/api/notify_send', {'title': title, 'message': message})
        if status != 200:
            raise RuntimeError(data.get('error', status))
        return 'Notification sent.'

    # ── display control (also used directly by hub/voice_shortcuts) ─────────────────────────
    # STATUS: closing a native full-screen app is the only display-clearing action confirmed in the
    # protocol; there is no known "blank the dashboard" command, so hiding = closing the open app.
    async def t_close_display(self):
        closed = await self.hub.close_app()
        return f'Closed {closed}.' if closed else 'No full-screen app was open; the display is on the dashboard.'

    async def t_show_dashboard(self):
        closed = await self.hub.close_app()
        return 'Back to the dashboard.' if closed else 'Already on the dashboard.'

    async def t_show_weather(self):
        summary = await self.hub.push_weather()
        return f'Weather: {summary}'

    async def t_adjust_brightness(self, delta):
        status = self.hub.glasses_status() or {}
        cur = status.get('brightness_level')
        cur = int(cur) if isinstance(cur, (int, float)) else 25
        level = max(1, min(50, cur + int(delta)))
        return await self.t_set_brightness(level=level)
