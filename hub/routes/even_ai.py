"""Even AI (SID 0x07): protocol lives in g2/even_ai.py; this is the hub's session plumbing —
WAKE_UP → listen → transcribe → Claude (with the glasses tools) or a canned reply → REPLY."""
import asyncio
from types import SimpleNamespace

from aiohttp import web

from g2 import even_ai as ai
from g2 import evenhub as eh
from hub import assistant_tools, calendar_events, live_translate_mic, paths, state, translate_live, voice_shortcuts
from hub import even_ai_assistant as eai
from hub.events import broadcast, notify_state_changed, on_event, to_json
from hub.routes import calendar as cal
from hub.routes import news, tasks
from hub.routes import weather as weather_routes
from hub.routes.settings import short_home

AI_CTRL_WAKE_UP, AI_CTRL_ENTER, AI_CTRL_EXIT = ai.CTRL_WAKE_UP, ai.CTRL_ENTER, ai.CTRL_EXIT
AI_REPLY_MAX_BYTES = ai.REPLY_MAX_BYTES

AI_MODES = ('off', 'enter', 'canned', 'claude')
AI_DEFAULTS = {
    'mode': 'off',            # off: ignore wake | enter: just open Even AI | canned: fixed reply | claude: ask Claude
    'listen': True,           # capture + transcribe what the user says after ENTER
    'listen_seconds': 20,     # hard cap; normally ends ~1.2 s after the user stops talking
    'show_question': True,    # show the transcript on-glass (ASK)
    'fallback_question': '',  # ASK text when nothing was transcribed (blank = skip ASK)
    'canned_reply': 'Hello from the hub. This answer was injected over SID 0x07.',
    'model': eai.DEFAULT_MODEL,
    'voice_shortcuts': True,  # spoken commands ("hide display", "brightness up") run directly, skipping Claude
    'tools': True,            # let Claude read news, manage tasks/calendar, change settings
    'effort': 'low',
    'system': eai.DEFAULT_SYSTEM,
    'stt_backend': eai.DEFAULT_STT_BACKEND,   # deepgram (cloud, default) | local (offline faster-whisper, optional)
    'stt_model': eai.DEFAULT_STT_MODEL,       # faster-whisper model name for the local backend
}
_ai_responder = eai.ClaudeResponder()
_ai_turn_lock = asyncio.Lock()

_OLD_DEFAULT_SYSTEM = (
    "You are the voice assistant on Even Realities G2 smart glasses. The user spoke a question; "
    "your answer is shown as plain text on a small monochrome display. Answer in at most three "
    "short sentences. No markdown, no lists, no emoji.")


async def _ai_send(session, payload, label, quiet=False):
    frames = eh.frame_pb(payload, ai.SID, eh.FLAG_REQUEST, session.next_seq())
    if not quiet:
        on_event(f'Even AI → {label} pb={payload.hex()[:64]}', level='info')
    await session._send_right(frames)


async def _ai_heartbeat_loop(session):
    count = 0
    try:
        while True:
            await asyncio.sleep(ai.HEARTBEAT_INTERVAL_S)
            count += 1
            await _ai_send(session, ai.build_heartbeat(session.next_magic(), count), 'HEARTBEAT', quiet=True)
    except asyncio.CancelledError:
        raise
    except Exception as e:
        on_event(f'Even AI heartbeat stopped: {e}', level='warn')


def ai_stop_heartbeat():
    task = state.context.pop('ai_hb_task', None)
    if task and not task.done():
        task.cancel()


async def ai_send_ctrl(session, status):
    await _ai_send(session, ai.build_ctrl(session.next_magic(), status), f'CTRL {ai.CTRL_NAMES.get(status, status)}')
    if status == ai.CTRL_ENTER:
        ai_stop_heartbeat()
        state.context['ai_hb_task'] = state.SUP.spawn(_ai_heartbeat_loop(session), name='even-ai-heartbeat',
                                                      scope='connection')
    elif status == ai.CTRL_EXIT:
        ai_stop_heartbeat()


async def ai_send_ask(session, text):
    await _ai_send(session, ai.build_ask(session.next_magic(), text), f'ASK {text[:40]!r}')


async def ai_send_analyse(session):
    await _ai_send(session, ai.build_analyse(session.next_magic()), 'ANALYSE (thinking)')


async def ai_send_reply(session, text, chunk_bytes=ai.REPLY_MAX_BYTES):
    chunks = ai.reply_chunks(text, chunk_bytes)
    for i, chunk in enumerate(chunks):
        last = i == len(chunks) - 1
        await _ai_send(session, ai.build_reply(session.next_magic(), chunk, last),
                       f'REPLY {i + 1}/{len(chunks)}{" (end)" if last else ""}')
        if not last:
            await asyncio.sleep(ai.REPLY_PACE_S)


def ai_settings():
    cfg = {**AI_DEFAULTS, **(state.load_hub_state().get('even_ai') or {})}
    if cfg.get('system') == _OLD_DEFAULT_SYSTEM:      # untouched old default → current default
        cfg['system'] = eai.DEFAULT_SYSTEM
    if cfg.get('listen_seconds') == 8:                # old default cap cut long questions off
        cfg['listen_seconds'] = AI_DEFAULTS['listen_seconds']
    return cfg


def ai_status(phase, **extra):
    """Live Even AI status for the page (not kept in the log history)."""
    state.context['ai_phase'] = {'phase': phase, **extra}
    broadcast(to_json({'type': 'ai', 'phase': phase, **extra}))


async def _ai_capture(session, turn, max_s):
    """Collect mic packets until the user stops talking (hub-side silence detection on the left
    lens), the glasses send VAD_END/TIMEOUT or EXIT, or max_s passes. The mic subscription is
    always turned off again, even if the turn is cancelled (disconnect) or fails."""
    await session.start_audio_stream()
    packets = []
    try:
        while not session.audio_packets.empty():
            session.audio_packets.get_nowait()
        vad = eai.SilenceDetector()
        loop = asyncio.get_running_loop()
        deadline = loop.time() + max_s
        while loop.time() < deadline and not turn['vad_end'].is_set() and not turn['exit'].is_set():
            try:
                arm, packet = await asyncio.wait_for(session.audio_packets.get(), timeout=0.2)
            except asyncio.TimeoutError:
                continue
            packets.append((arm, packet))
            if arm == 'L' and vad.feed(packet):
                on_event(f'Even AI: {"end of speech" if vad.heard_speech else "no speech"} detected after {vad.elapsed:.1f}s', level='info')
                break
        while not session.audio_packets.empty():
            packets.append(session.audio_packets.get_nowait())
    finally:
        try:
            await asyncio.shield(session.stop_audio_stream())
        except Exception as e:
            on_event(f'Even AI: could not stop the mic stream: {e}', level='warn')
    return packets


TRANSLATE_DEFAULTS = {'on': False, 'src': 'EN', 'dst': 'ES'}


def translate_mode():
    """Live-translate state persisted in hub state: {on, src, dst}."""
    return {**TRANSLATE_DEFAULTS, **(state.load_hub_state().get('translate_live') or {})}


async def translate_utterance(session, text, cfg=None, entry=None):
    """Live-translate one transcript: Claude translates, the glasses Translate app shows
    original + translation. Returns the translation. Raises RuntimeError on failure."""
    tm = translate_mode()
    translated = await translate_live.translate(text, tm['src'], tm['dst'])
    if state.APPS_CTL.current != 'translate':
        await state.APPS_CTL.translate_open(tm['src'], tm['dst'])
    await state.APPS_CTL.translate_text(text, translated, True)
    on_event(f'Live translate {tm["src"]}>{tm["dst"]}: "{text}" -> "{translated}"', level='ok')
    if entry is not None:
        entry['reply'] = translated
        entry['source'] = 'translate'
    return translated


def on_translate_closed_on_glasses():
    """The user closed Translate ON THE GLASSES (SID 0x05 NOTIFY CLOSE). That ends wake-based live
    translate: otherwise the persisted `on` flag keeps hijacking every later Even AI wake gesture and
    re-opening Translate (seen live: "What time is it?" answered by opening Translate days after the
    toggle was switched on). Returns True if live translate was switched off."""
    tm = translate_mode()
    if not tm['on']:
        return False
    tm['on'] = False
    state.save_hub_state('translate_live', tm)
    on_event('Live translate OFF: Translate was closed on the glasses, so the wake gesture '
             'opens Even AI again', level='info')
    notify_state_changed('translate_live')
    return True


async def ai_handle_wake(session):
    """WAKE_UP → per the configured mode: ENTER, listen, transcribe, ASK, ANALYSE, REPLY, log.
    With live translate ON the transcript is translated and pushed to the Translate app instead."""
    if MIC_TRANSLATOR.is_running() and MIC_TRANSLATOR.source_name == 'glasses':
        return          # continuous glasses-mic translate owns the mic stream; a wake would fight it
    cfg = ai_settings()
    tmode = translate_mode()
    if tmode['on']:      # translate overrides off/enter: it still needs listening
        cfg = {**cfg, 'listen': True, 'mode': cfg['mode'] if cfg['mode'] in ('canned', 'claude') else 'canned'}
    if cfg['mode'] == 'off':
        return
    if _ai_turn_lock.locked():
        on_event('Even AI: wake ignored — a turn is already running', level='info')
        return
    async with _ai_turn_lock:
        turn = {'vad_end': asyncio.Event(), 'exit': asyncio.Event()}
        state.context['ai_turn'] = turn
        entry = {'mode': cfg['mode'], 'question': '', 'reply': ''}
        try:
            await ai_send_ctrl(session, AI_CTRL_ENTER)
            if cfg['mode'] == 'enter':
                ai_status('open')
                return

            question = ''
            if cfg['listen']:
                caps = eai.capabilities()
                if not caps['audio_decoder']:
                    on_event('Even AI: audio decoder missing — run the hub with .venv/bin/python', level='warn')
                else:
                    ai_status('listening')
                    packets = await _ai_capture(session, turn, float(cfg['listen_seconds']))
                    pcm, arm, n = await asyncio.to_thread(eai.decode_packets, packets)
                    secs = len(pcm) / 2 / eai.SAMPLE_RATE
                    on_event(f'Even AI: captured {n} audio packets from lens {arm or "-"} ({secs:.1f}s)',
                             level='ok' if n else 'warn')
                    entry['audio_s'] = round(secs, 1)
                    if turn['exit'].is_set():
                        ai_status('idle')
                        return
                    if pcm:
                        ai_status('transcribing')
                        try:
                            question, conf = await eai.transcribe_ex(pcm, eai.SAMPLE_RATE, cfg['stt_backend'], cfg['stt_model'])
                            entry['confidence'] = round(conf, 3)
                            on_event(f'Even AI heard: "{question}" ({conf:.0%})', level='ok')
                        except Exception as e:
                            entry['error'] = str(e)
                            on_event(f'Even AI transcription failed: {e}', level='err')
            entry['question'] = question
            ai_status('heard', question=question)

            if tmode['on']:
                if not question:
                    on_event('Live translate: nothing heard', level='warn')
                    ai_status('idle')
                    return
                ai_status('thinking', question=question)
                try:
                    translated = await translate_utterance(session, question, cfg, entry)
                    ai_status('answered', question=question, reply=translated)
                except Exception as e:
                    entry['error'] = str(e)
                    on_event(f'Live translate failed: {e}', level='err')
                    ai_status('error', message=str(e))
                return

            shortcut_reply = await eai.run_shortcut(question, ASSISTANT_TOOLS.run, cfg, entry) if cfg['mode'] != 'enter' else None
            if shortcut_reply is not None:      # handled locally: no Claude round-trip
                if cfg['show_question']:
                    await ai_send_ask(session, question)
                    await asyncio.sleep(0.3)
                entry['reply'] = shortcut_reply
                if turn['exit'].is_set():
                    ai_status('idle')
                    return
                await ai_send_reply(session, shortcut_reply)
                ai_status('answered', question=question, reply=shortcut_reply)
                return

            shown_q = question or cfg['fallback_question']
            if cfg['show_question'] and shown_q:
                await ai_send_ask(session, shown_q)
                await asyncio.sleep(0.3)
            await ai_send_analyse(session)
            ai_status('thinking', question=question)

            if cfg['mode'] == 'claude':
                if not question:
                    reply = "Sorry, I didn't catch that."
                else:
                    try:
                        reply, model = await ask_claude(question, cfg, entry)
                        entry['model'] = model
                    except Exception as e:
                        entry['error'] = str(e)
                        on_event(f'Even AI {e}', level='err')
                        reply = 'Sorry, the assistant is unavailable right now.'
            else:
                reply = cfg['canned_reply'] or '(no reply configured)'
            entry['reply'] = reply
            if turn['exit'].is_set():
                ai_status('idle')
                return
            await ai_send_reply(session, reply)
            ai_status('answered', question=question, reply=reply)
        except asyncio.CancelledError:
            entry['error'] = 'cancelled (glasses disconnected)'
            ai_status('idle')
            raise
        except Exception as e:
            entry['error'] = str(e)
            on_event(f'Even AI turn failed: {e}', level='err')
            ai_status('error', message=str(e))
        finally:
            state.context.pop('ai_turn', None)
            if cfg['mode'] != 'enter':
                state.STORE.add_ai_log(state.active_device_id(), entry)
                notify_state_changed('even_ai_log')


# ── the tools Claude can use (hub/assistant_tools.py) ───────────────────────────────────────
async def _tool_save_tasks(task_list):
    items = [{'uid': t.get('uid'), 'title': t['title'], 'completed': bool(t.get('completed'))} for t in task_list]
    if state.current_session() is not None:
        status, data = await tasks.push_quicklist(items)
        if status != 200:
            raise RuntimeError(data.get('error', status))
    else:
        state.save_hub_state('quicklist', {'items': [t['title'] for t in items], 'tasks': items})
    notify_state_changed('quicklist')


async def _tool_set_calendar(events):
    st = cal.calendar_state()
    cal.save_calendar([calendar_events.normalize(e) for e in events], st['h24'])
    session = state.current_session()
    if session is not None:
        await cal.push_calendar(session)
    notify_state_changed('calendar')


async def _tool_refresh_news():
    news.refresh_in_background(force_fetch=True)


async def _tool_close_app():
    """Close the open native full-screen app; returns its name (None if none was open)."""
    name = state.APPS_CTL.current
    await state.APPS_CTL.close()
    return name


async def _tool_push_weather():
    session = state.current_session()
    if session is None:
        raise RuntimeError('glasses not connected')
    _ok, summary = await weather_routes.push_weather(session)
    return summary


TOOL_HUB = SimpleNamespace(
    close_app=_tool_close_app,
    push_weather=_tool_push_weather,
    news_stories=lambda: (state.load_news_cache() or {}).get('stories', []),
    refresh_news=_tool_refresh_news,
    load_tasks=lambda: tasks.load_tasks(),
    save_tasks=_tool_save_tasks,
    calendar_state=lambda: cal.calendar_state(),
    set_calendar=_tool_set_calendar,
    weather_now=lambda: state.context.get('weather_now'),
    glasses_status=lambda: state.context.get('glasses_status') or {},
    post=lambda path, body: state.post_self(path, body),
)
ASSISTANT_TOOLS = assistant_tools.AssistantTools(TOOL_HUB)


async def ask_claude(question, cfg, entry):
    """Ask Claude with the glasses tools (unless disabled); log each tool call."""
    use_tools = cfg.get('tools', True)
    reply, model, actions = await _ai_responder.ask(
        question, cfg['model'], cfg['effort'], cfg['system'],
        tools=assistant_tools.TOOLS if use_tools else None,
        run_tool=ASSISTANT_TOOLS.run if use_tools else None)
    for a in actions:
        on_event(f'Even AI tool: {a}', level='warn' if a.endswith('FAILED') else 'ok')
    if entry is not None and actions:
        entry['actions'] = actions
    return reply, model


# ── frames from the glasses on SID 0x07 (called by hub.frames) ─────────────────────────────
def on_ai_frame(cmd_id, pb):
    msg = ai.decode(pb)
    value = msg['value']
    ctrl = value if cmd_id == ai.CMD_CTRL else None
    if cmd_id != ai.CMD_HEARTBEAT:
        on_event(f'Even AI ← {msg["label"]} magic={msg["magic"]} pb={pb.hex()}', level='ok')
    session = state.context.get('session')
    turn = state.context.get('ai_turn')
    if cmd_id == ai.CMD_VAD_INFO and turn:
        if value in (ai.VAD_END, ai.VAD_TIMEOUT):   # user stopped talking → stop listening
            turn['vad_end'].set()
        elif value == ai.VAD_START:
            ai_status('listening', speaking=True)
    if ctrl == AI_CTRL_EXIT:
        ai_stop_heartbeat()
        if turn:
            turn['exit'].set()
        ai_status('idle')
    elif ctrl == AI_CTRL_WAKE_UP and session is not None:
        state.SUP.spawn(ai_handle_wake(session), name='even-ai-turn', scope='connection')


# ── HTTP ───────────────────────────────────────────────────────────────────────────────────
async def api_ai_settings(request):
    if request.method == 'GET':
        return web.json_response({'settings': ai_settings(), 'capabilities': eai.capabilities(),
                                  'phase': state.context.get('ai_phase', {'phase': 'idle'}), 'models': eai.MODELS,
                                  'tools': [t['name'] for t in assistant_tools.TOOLS],
                                  'voice_shortcuts': voice_shortcuts.shortcut_list(),
                                  'env_file': short_home(paths.env_files()[0])})
    data = await request.json()
    if not isinstance(data, dict):
        return web.json_response({'error': 'JSON object required'}, status=400)
    cfg = ai_settings()
    for k, default in AI_DEFAULTS.items():
        if k in data:
            v = data[k]
            try:
                cfg[k] = type(default)(v) if not isinstance(default, bool) else bool(v)
            except (TypeError, ValueError):
                return web.json_response({'error': f'{k}: expected {type(default).__name__}'}, status=400)
    if cfg['mode'] not in AI_MODES:
        return web.json_response({'error': f'mode must be one of {AI_MODES}'}, status=400)
    if cfg['stt_backend'] not in eai.STT_BACKENDS:
        return web.json_response({'error': f'stt_backend must be one of {eai.STT_BACKENDS}'}, status=400)
    cfg['stt_model'] = cfg['stt_model'].strip() or eai.DEFAULT_STT_MODEL
    cfg['listen_seconds'] = max(2, min(30, cfg['listen_seconds']))
    if cfg['effort'] not in ('low', 'medium', 'high', 'xhigh', 'max'):
        cfg['effort'] = 'low'
    if cfg['model'] not in eai.MODELS:
        return web.json_response({'error': f'unknown model; choose one of {list(eai.MODELS)}'}, status=400)
    state.save_hub_state('even_ai', cfg)
    on_event(f'Even AI mode: {cfg["mode"]}', level='info')
    return web.json_response({'settings': cfg})


async def api_ai_history(request):
    try:
        limit = max(1, min(500, int(request.query.get('limit', 50))))
    except ValueError:
        return web.json_response({'error': 'limit must be a number'}, status=400)
    rows = await asyncio.to_thread(state.STORE.ai_log, state.active_device_id(), limit)
    return web.json_response({'history': rows})


async def api_ai_try(request):
    """Run the reply step for a typed question without the glasses (tests the key/model/prompt)."""
    try:
        data = await request.json()
    except Exception:
        data = None
    if not isinstance(data, dict):
        return web.json_response({'error': 'JSON object required'}, status=400)
    question = str(data.get('question') or '').strip()
    if not question:
        return web.json_response({'error': 'question required'}, status=400)
    cfg = ai_settings()
    if cfg['mode'] not in ('canned', 'claude'):
        # Off / Open only never answer on the glasses, so a test answer here would be made up
        # (it used to return the auto-reply text and log it as a real question).
        return web.json_response({'error': 'Even AI is set to give no answer. Choose Auto-reply or Claude under '
                                           '"When Even AI wakes", then try again.'}, status=409)
    try:
        if cfg['mode'] == 'claude':
            reply, model = await ask_claude(question, cfg, None)
        else:
            reply, model = cfg['canned_reply'], None
    except Exception as e:
        return web.json_response({'error': str(e)}, status=502)
    state.STORE.add_ai_log(state.active_device_id(), {'mode': cfg['mode'], 'question': question, 'reply': reply,
                                                      'model': model, 'source': 'typed'})
    notify_state_changed('even_ai_log')
    return web.json_response({'reply': reply, 'model': model})


async def api_translate_mode(request):
    """GET: current live-translate state. POST {on, src, dst}: enable/disable + set languages.
    Speech still needs the glasses' WAKE_UP/ENTER gesture: the hub cannot listen continuously."""
    if request.method == 'GET':
        return web.json_response({**translate_mode(), 'languages': translate_live.LANGUAGES, 'note': TRANSLATE_NOTE})
    try:
        data = await request.json()
    except Exception:
        data = None
    if not isinstance(data, dict):
        return web.json_response({'error': 'JSON object required'}, status=400)
    tm = translate_mode()
    for k in ('src', 'dst'):
        if k in data:
            v = str(data[k] or '').strip()
            if not v or len(v) > 40:
                return web.json_response({'error': f'{k}: language code or name required'}, status=400)
            tm[k] = v
    if 'on' in data:
        tm['on'] = bool(data['on'])
    state.save_hub_state('translate_live', tm)
    opened = False
    if tm['on'] and state.current_session() is not None:
        try:
            await state.APPS_CTL.translate_open(tm['src'], tm['dst'])
            opened = True
        except Exception as e:
            on_event(f'Live translate: could not open Translate app: {e}', level='warn')
    on_event(f'Live translate {"ON" if tm["on"] else "OFF"} ({tm["src"]}>{tm["dst"]}); ' + TRANSLATE_NOTE, level='info')
    notify_state_changed('translate_live')
    return web.json_response({**tm, 'opened': opened, 'note': TRANSLATE_NOTE})


TRANSLATE_NOTE = ('Speak after the glasses wake gesture (Even AI WAKE_UP): the mic only streams after it, '
                  'so each utterance needs the gesture; there is no continuous listening.')


async def _mic_stt(pcm):
    cfg = ai_settings()
    return await eai.transcribe_ex(pcm, live_translate_mic.SAMPLE_RATE, cfg['stt_backend'], cfg['stt_model'])


async def _mic_push(src, dst, original, translated):
    if state.current_session() is None:
        raise RuntimeError('glasses not connected')
    if state.APPS_CTL.current != 'translate':
        await state.APPS_CTL.translate_open(src, dst)
    await state.APPS_CTL.translate_text(original, translated, True)


def _mic_spawn(coro, name):
    return state.SUP.spawn(coro, name=name, scope='app')


def _glasses_session():
    return state.current_session()


def _glasses_check():
    return live_translate_mic.glasses_problem(_glasses_session(), eai.capabilities()['audio_decoder'])


async def _glasses_arm_evenhub(session):
    """Strategy 1: EvenHub audio control (SID 0xE0 cmd 15). Streams 0x6402 without opening an
    Even AI session, so the Translate screen stays up. Toggle off/on so a re-arm really restarts it."""
    await session.enable_mic(False)
    await session.enable_mic(True)


async def _glasses_arm_even_ai(session):
    """Strategy 2: Even AI CTRL ENTER (+ 2 s heartbeat) then subscribe: the proven live mic path."""
    await ai_send_ctrl(session, AI_CTRL_ENTER)
    await session.start_audio_stream()


async def _glasses_disarm(session):
    ai_stop_heartbeat()
    try:
        await session.stop_audio_stream()
    finally:
        try:
            await session.enable_mic(False)
        except Exception:
            pass
    if state.context.get('ai_enter_by_live'):
        state.context.pop('ai_enter_by_live', None)
        await ai_send_ctrl(session, AI_CTRL_EXIT)


async def _glasses_arm_even_ai_tracked(session):
    state.context['ai_enter_by_live'] = True
    await _glasses_arm_even_ai(session)


def _make_glasses_source():
    session = _glasses_session()
    problem = live_translate_mic.glasses_problem(session, eai.capabilities()['audio_decoder'])
    if problem:
        raise live_translate_mic.MicUnavailable(problem)
    src = live_translate_mic.GlassesMicSource(
        session, eai.Lc3Stream, [_glasses_arm_evenhub, _glasses_arm_even_ai_tracked], [_glasses_disarm],
        report=on_event)
    return _prime_glasses_source(src)


async def _prime_glasses_source(src):
    await src.arm(first=True)
    return src


def _make_mic_translator():
    return live_translate_mic.LiveMicTranslator(
        _mic_stt, lambda t, s, d: translate_live.translate(t, s, d), _mic_push,
        source_factory=lambda: live_translate_mic.SoundDeviceSource(), spawn=_mic_spawn, report=on_event,
        glasses_factory=_make_glasses_source, glasses_check=_glasses_check)


MIC_TRANSLATOR = _make_mic_translator()


async def api_translate_live_start(request):
    """POST {src, dst, source}: translate continuously. source 'glasses' = the glasses' own mic (LC3 on
    0x6402, auto re-armed), 'device' = the host mic (needs `.[mic]`). Default: glasses when they are
    connected and the LC3 decoder exists, else device."""
    try:
        data = await request.json()
    except Exception:
        data = None
    if not isinstance(data, dict):
        return web.json_response({'error': 'JSON object required'}, status=400)
    tm = translate_mode()
    langs = {}
    for k in ('src', 'dst'):
        v = str(data.get(k) or tm[k]).strip()
        if not v or len(v) > 40:
            return web.json_response({'error': f'{k}: language code or name required'}, status=400)
        langs[k] = v
    source = data.get('source')
    if source in (None, ''):
        source = MIC_TRANSLATOR.default_source()
    elif source not in ('glasses', 'device'):
        return web.json_response({'error': "source must be 'glasses' or 'device'"}, status=400)
    try:
        await MIC_TRANSLATOR.start(langs['src'], langs['dst'], source)
    except live_translate_mic.MicUnavailable as e:
        body = {'error': str(e), 'source': source, 'mic_available': live_translate_mic.mic_available(),
                'glasses_mic_available': MIC_TRANSLATOR.glasses_problem() is None}
        if source == 'glasses':
            body['suggest'] = 'device'
        return web.json_response(body, status=503)
    notify_state_changed('translate_live')
    return web.json_response(MIC_TRANSLATOR.status())


async def api_translate_live_stop(request):
    await MIC_TRANSLATOR.stop()
    notify_state_changed('translate_live')
    return web.json_response(MIC_TRANSLATOR.status())


async def api_translate_live_status(request):
    return web.json_response(MIC_TRANSLATOR.status())


async def api_ai_voice_test(request):
    """Run typed text through the same voice-shortcut match + execute path, no glasses mic needed."""
    try:
        data = await request.json()
    except Exception:
        data = None
    text = str((data or {}).get('text') or '').strip() if isinstance(data, dict) else ''
    if not text:
        return web.json_response({'error': 'text required'}, status=400)
    hit = voice_shortcuts.match(text)
    if hit is None:
        on_event(f'Voice test: "{text}" matched no shortcut (Claude would handle it)', level='info')
        return web.json_response({'matched': False, 'text': text, 'action': None, 'args': {}})
    action, args = hit
    out = {'matched': True, 'text': text, 'action': action, 'args': args}
    try:
        out['result'] = str(await ASSISTANT_TOOLS.run(action, dict(args)))
        on_event(f'Voice test: "{text}" -> {action} {args}', level='ok')
    except Exception as e:
        out['error'] = str(e)
        on_event(f'Voice test: "{text}" -> {action} FAILED: {e}', level='warn')
    return web.json_response(out)


async def api_ai_reset(request):
    _ai_responder.reset()
    on_event('Even AI: Claude conversation reset', level='info')
    return web.json_response({'ok': True})


ROUTES = [
    ('GET', '/api/ai_settings', api_ai_settings),
    ('POST', '/api/ai_settings', api_ai_settings),
    ('GET', '/api/ai_history', api_ai_history),
    ('POST', '/api/ai_try', api_ai_try),
    ('POST', '/api/ai_reset', api_ai_reset),
    ('GET', '/api/translate/mode', api_translate_mode),
    ('POST', '/api/translate/mode', api_translate_mode),
    ('GET', '/api/translate/live', api_translate_live_status),
    ('POST', '/api/translate/live/start', api_translate_live_start),
    ('POST', '/api/translate/live/stop', api_translate_live_stop),
    ('POST', '/api/ai/voice_test', api_ai_voice_test),
]
