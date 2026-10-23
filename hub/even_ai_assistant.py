"""Even AI assistant back-end for the hub: mic audio → transcript → reply (canned or Claude),
plus a persistent question/answer log.

Audio: after the hub answers WAKE_UP with CTRL ENTER, the glasses stream LC3 mic audio (16 kHz,
10 ms frames, 5×40-byte frames = 200 audio bytes per packet + trailer) on notify char 0x6402.
Transcription: Deepgram prerecorded REST (same settings as deepgram_stt.py).
Keys: environment variables, else KEY=value lines in ~/.config/g2hub/.env, else hub/.env
(DEEPGRAM_API_KEY, ANTHROPIC_API_KEY). The files are re-read only when they change.
"""
import asyncio
import importlib.util
import io
import json
import logging
import os
import time
import wave

import aiohttp

try:
    import lc3
except ImportError:  # hub still runs on plain system python; audio features report as unavailable
    lc3 = None
try:
    import anthropic
except ImportError:
    anthropic = None

from hub import paths, voice_shortcuts

HERE = os.path.dirname(os.path.abspath(__file__))
ENV_FILE = os.path.join(HERE, '.env')          # legacy location; see paths.env_files()
LOG_FILE = os.path.join(HERE, 'even_ai_log.jsonl')

SAMPLE_RATE = 16000
FRAME_BYTES = 40
FRAMES_PER_PACKET = 5
AUDIO_BYTES = FRAME_BYTES * FRAMES_PER_PACKET

DEEPGRAM_URL = 'https://api.deepgram.com/v1/listen?punctuate=true&smart_format=true'

DEFAULT_MODEL = 'claude-opus-5'
# Claude models offered in the hub. `effort` is not accepted by Haiku 4.5; the server-side refusal
# fallback is only used where it is documented (Opus 5 / Opus 5.5 / Fable).
MODELS = {
    'claude-opus-5': 'Opus 5 — best balance (default)',
    'claude-sonnet-5': 'Sonnet 5 — faster, cheaper',
    'claude-haiku-4-5': 'Haiku 4.5 — fastest, cheapest',
    'claude-opus-5-5': 'Opus 5.5 — newest Opus',
    'claude-fable-5-1': 'Fable 5.1 — most capable, slowest, priciest',
}
_NO_EFFORT = {'claude-haiku-4-5'}
_FALLBACK = {'claude-opus-5', 'claude-opus-5-5', 'claude-fable-5-1', 'claude-fable-5'}
MAX_TOOL_ROUNDS = 8
DEFAULT_SYSTEM = (
    "You are the voice assistant on the user's Even Realities G2 smart glasses, running on their own "
    "hub. The user spoke to you; your answer is shown as plain text on a small monochrome display "
    "and read on the move. Keep answers to one to three short sentences unless the user asks you to "
    "read something (an article, a list), in which case give the full text. No markdown, lists, "
    "symbols or emoji. You can see and control the glasses' widgets and settings with your tools: "
    "news, tasks, calendar, weather, notifications, brightness, silent mode and the display (hide or "
    "close the display, show the dashboard). Use them whenever "
    "the request involves them, then confirm briefly what you did.")
IDLE_RESET_S = 300
MAX_HISTORY = 20


_env_cache = {}   # path -> (mtime_ns, {KEY: value})


def _read_env_file(path):
    try:
        mtime = os.stat(path).st_mtime_ns
    except OSError:
        _env_cache.pop(str(path), None)
        return {}
    cached = _env_cache.get(str(path))
    if cached and cached[0] == mtime:
        return cached[1]
    values = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if '=' in line and not line.startswith('#'):
                    k, v = line.split('=', 1)
                    values[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        return {}
    _env_cache[str(path)] = (mtime, values)
    return values


def get_key(name):
    """Environment first, then ~/.config/g2hub/.env, then hub/.env. Never logged."""
    val = os.environ.get(name)
    if val:
        return val.strip()
    for path in paths.env_files():
        val = _read_env_file(path).get(name)
        if val:
            return val
    return None


log = logging.getLogger('g2hub.stt')
STT_BACKENDS = ('deepgram', 'local')
DEFAULT_STT_BACKEND = 'deepgram'
DEFAULT_STT_MODEL = 'base'
LOCAL_STT_HINT = ("pip install -e '.[stt-local]' (installs faster-whisper; the model downloads on first use)")


def local_stt_available():
    """True when the optional faster-whisper package is installed (checked without importing it)."""
    try:
        return importlib.util.find_spec('faster_whisper') is not None
    except (ImportError, ValueError):
        return False


def capabilities():
    return {'stt_local': local_stt_available(), 'audio_decoder': lc3 is not None, 'anthropic_sdk': anthropic is not None,
            'deepgram_key': bool(get_key('DEEPGRAM_API_KEY')),
            'anthropic_key': bool(get_key('ANTHROPIC_API_KEY'))}


class Lc3Stream:
    """Decodes one lens's mic packets to 16-bit PCM."""

    def __init__(self):
        self.decoder = lc3.Decoder(frame_duration_us=10000, sample_rate_hz=SAMPLE_RATE, num_channels=1)

    def decode(self, packet):
        if len(packet) < AUDIO_BYTES:
            return b''
        pcm = bytearray()
        for i in range(FRAMES_PER_PACKET):
            try:
                pcm.extend(self.decoder.decode(packet[i * FRAME_BYTES:(i + 1) * FRAME_BYTES], bit_depth=16))
            except Exception:
                pass
        return bytes(pcm)


class SilenceDetector:
    """Ends listening when the user stops talking. The glasses never send VAD_END in practice
    (live 2026-09-29), so the hub decides: learn the background level from the first ~0.4 s,
    call a packet "speech" when it is clearly louder, and finish after `silence_s` of quiet once
    speech was heard (or after `no_speech_s` if nobody spoke at all). Feed it one packet at a time."""

    def __init__(self, silence_s=1.2, no_speech_s=6.0, min_level=400.0):
        self.stream = Lc3Stream() if lc3 is not None else None
        self.silence_s, self.no_speech_s, self.min_level = silence_s, no_speech_s, min_level
        self.elapsed = 0.0
        self.noise = None
        self._calib = []
        self.heard_speech = False
        self.quiet_for = 0.0

    @staticmethod
    def _rms(pcm):
        import array
        import math
        samples = array.array('h', pcm)
        return math.sqrt(sum(s * s for s in samples) / len(samples)) if samples else 0.0

    def feed(self, packet):
        """Returns True when listening should stop."""
        if self.stream is None:
            return False
        pcm = self.stream.decode(packet)
        if not pcm:
            return False
        dt = len(pcm) / 2 / SAMPLE_RATE
        self.elapsed += dt
        level = self._rms(pcm)
        if self.noise is None:
            self._calib.append(level)
            if self.elapsed >= 0.4:
                self.noise = sorted(self._calib)[len(self._calib) // 2]
            return False
        speaking = level > max(self.min_level, self.noise * 3.0)
        if speaking:
            self.heard_speech = True
            self.quiet_for = 0.0
        else:
            self.quiet_for += dt
        if self.heard_speech:
            return self.quiet_for >= self.silence_s
        return self.elapsed >= self.no_speech_s


def decode_packets(packets):
    """packets: list of (arm, bytes). Uses the left lens if it streamed, else the right
    (jarvis_loop found the left mic cleaner). Returns (pcm, arm, packet_count)."""
    if lc3 is None or not packets:
        return b'', None, 0
    arms = {a for a, _ in packets}
    arm = 'L' if 'L' in arms else 'R'
    stream = Lc3Stream()
    chosen = [p for a, p in packets if a == arm]
    return b''.join(stream.decode(p) for p in chosen), arm, len(chosen)


def pcm_to_wav(pcm, sample_rate=SAMPLE_RATE):
    buf = io.BytesIO()
    with wave.open(buf, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sample_rate)
        w.writeframes(pcm)
    return buf.getvalue()


async def transcribe(pcm, sample_rate=SAMPLE_RATE):
    """Deepgram backend. Returns (transcript, confidence). Raises RuntimeError with a readable message."""
    key = get_key('DEEPGRAM_API_KEY')
    if not key:
        raise RuntimeError('DEEPGRAM_API_KEY not set (env or .env)')
    async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=30)) as sess:
        async with sess.post(DEEPGRAM_URL, data=pcm_to_wav(pcm, sample_rate),
                             headers={'Authorization': f'Token {key}', 'Content-Type': 'audio/wav'}) as r:
            body = await r.text()
            if r.status != 200:
                raise RuntimeError(f'Deepgram HTTP {r.status}: {body[:200]}')
    alt = json.loads(body)['results']['channels'][0]['alternatives'][0]
    return alt.get('transcript', '').strip(), float(alt.get('confidence', 0.0))


_local_models = {}      # model name -> loaded WhisperModel (loaded lazily, once)


def _local_transcribe_sync(pcm, sample_rate, model_name):
    try:
        from faster_whisper import WhisperModel
        import numpy as np
    except ImportError as e:
        raise RuntimeError(f'Local speech-to-text needs faster-whisper ({e}). Install: {LOCAL_STT_HINT}') from e
    model = _local_models.get(model_name)
    if model is None:
        log.info('loading faster-whisper model %r (first use may download it)', model_name)
        try:
            model = WhisperModel(model_name, device='cpu', compute_type='int8')
        except Exception as e:
            raise RuntimeError(f'Local speech-to-text could not load model {model_name!r}: {e}. '
                               'Check the model name and that it can be downloaded (network needed once).') from e
        _local_models[model_name] = model
    audio = np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0
    if sample_rate != 16000 and len(audio):          # whisper expects 16 kHz
        n = int(len(audio) * 16000 / sample_rate)
        audio = np.interp(np.linspace(0, len(audio) - 1, n), np.arange(len(audio)), audio).astype(np.float32)
    segments, _info = model.transcribe(audio, beam_size=1, vad_filter=True)
    segs = list(segments)
    text = ' '.join(sg.text.strip() for sg in segs).strip()
    conf = 0.0
    if segs:
        import math
        conf = sum(math.exp(min(0.0, sg.avg_logprob)) for sg in segs) / len(segs)
    return text, conf


async def transcribe_local(pcm, sample_rate=SAMPLE_RATE, model=DEFAULT_STT_MODEL):
    """Local backend (faster-whisper, CPU int8). Returns (transcript, confidence); RuntimeError if unusable."""
    if not local_stt_available():
        raise RuntimeError(f'Local speech-to-text is selected but faster-whisper is not installed. '
                           f'Install: {LOCAL_STT_HINT} — or switch Speech-to-text back to Deepgram.')
    return await asyncio.to_thread(_local_transcribe_sync, pcm, sample_rate, model or DEFAULT_STT_MODEL)


async def transcribe_ex(pcm, sample_rate=SAMPLE_RATE, backend=DEFAULT_STT_BACKEND, model=DEFAULT_STT_MODEL):
    """Dispatch on the stt_backend setting. Returns (transcript, confidence). Never returns silently
    wrong: failures raise RuntimeError with a user-readable message. Local falls back to Deepgram
    (logged) when it is unavailable and a Deepgram key exists."""
    if backend != 'local':
        return await transcribe(pcm, sample_rate)
    try:
        return await transcribe_local(pcm, sample_rate, model)
    except RuntimeError as e:
        if get_key('DEEPGRAM_API_KEY'):
            log.warning('local STT unavailable (%s); falling back to Deepgram', e)
            return await transcribe(pcm, sample_rate)
        log.error('local STT failed: %s', e)
        raise


async def transcribe_pcm(pcm_bytes, sample_rate=SAMPLE_RATE, backend=DEFAULT_STT_BACKEND, model=DEFAULT_STT_MODEL):
    """The STT seam: PCM16 mono bytes -> transcript text. backend/model come from the AI config."""
    return (await transcribe_ex(pcm_bytes, sample_rate, backend, model))[0]


class ClaudeResponder:
    """Rolling conversation with Claude; resets after IDLE_RESET_S of silence."""

    def __init__(self):
        self.messages = []
        self.last = 0.0
        self._client = None
        self._client_key = None

    def reset(self):
        self.messages = []

    def _get_client(self):
        key = get_key('ANTHROPIC_API_KEY')
        if not key:
            raise RuntimeError('ANTHROPIC_API_KEY not set (env or .env)')
        if self._client is None or key != self._client_key:
            # Transient 503/529 overloads happen; the SDK retries these with backoff.
            self._client = anthropic.AsyncAnthropic(api_key=key, max_retries=4, timeout=45.0)
            self._client_key = key
        return self._client

    def _trim(self, messages):
        """Keep the last MAX_HISTORY messages, starting at a plain user turn so no tool_result is
        separated from its tool_use."""
        if len(messages) <= MAX_HISTORY:
            return messages
        tail = messages[-MAX_HISTORY:]
        for i, m in enumerate(tail):
            if m['role'] == 'user' and isinstance(m['content'], str):
                return tail[i:]
        return []

    async def ask(self, question, model=DEFAULT_MODEL, effort='low', system=DEFAULT_SYSTEM,
                  tools=None, run_tool=None):
        """Answer `question`, letting Claude call `tools` (Anthropic tool schemas) through the async
        `run_tool(name, input) -> str`. Returns (text, model, actions) where actions lists the tool
        calls made, e.g. ['add_task(Buy milk)']."""
        if anthropic is None:
            raise RuntimeError('anthropic SDK not installed — run the hub with .venv/bin/python')
        client = self._get_client()
        if time.time() - self.last > IDLE_RESET_S:
            self.messages = []
        self.last = time.time()
        messages = self.messages + [{'role': 'user', 'content': question}]
        # The model has no clock: give it the local date and time so "what time is it?" works.
        now = time.strftime('%A %d %B %Y, %H:%M %Z')
        kwargs = dict(model=model, max_tokens=16000, system=f'{system or DEFAULT_SYSTEM}\n\nCurrent local date and time: {now}.')
        if model not in _NO_EFFORT:
            kwargs['output_config'] = {'effort': effort}
        if model in _FALLBACK:
            kwargs.update(betas=['server-side-fallback-2026-07-01'], fallbacks='default')
        if tools:
            kwargs['tools'] = tools
        actions = []
        for _ in range(MAX_TOOL_ROUNDS):
            try:
                response = await client.beta.messages.create(messages=messages, **kwargs)
            except anthropic.AuthenticationError:
                raise RuntimeError('Claude: invalid API key')
            except anthropic.NotFoundError:
                raise RuntimeError(f'Claude: unknown model "{model}"')
            except anthropic.RateLimitError:
                raise RuntimeError('Claude: rate limited, try again shortly')
            except anthropic.BadRequestError as e:
                raise RuntimeError(f'Claude: bad request: {e.message}')
            except anthropic.APIStatusError as e:
                raise RuntimeError(f'Claude: API error {e.status_code}')
            except anthropic.APIConnectionError:
                raise RuntimeError('Claude: network error')
            if response.stop_reason == 'refusal':
                return "Sorry, I can't help with that.", response.model, actions
            messages = messages + [{'role': 'assistant', 'content': response.content}]
            calls = [b for b in response.content if b.type == 'tool_use']
            if response.stop_reason != 'tool_use' or not calls or run_tool is None:
                text = ' '.join(b.text for b in response.content if b.type == 'text').strip()
                self.messages = self._trim(messages)
                return text, response.model, actions
            results = []
            for call in calls:
                args = call.input if isinstance(call.input, dict) else {}
                label = f"{call.name}({', '.join(str(v)[:30] for v in args.values())})"
                try:
                    out, is_error = str(await run_tool(call.name, args)), False
                except Exception as e:
                    out, is_error = f'Error: {e}', True
                actions.append(label + (' FAILED' if is_error else ''))
                results.append({'type': 'tool_result', 'tool_use_id': call.id, 'content': out[:20000],
                                'is_error': is_error})
            messages = messages + [{'role': 'user', 'content': results}]
        self.messages = []
        return 'Sorry, that took too many steps.', model, actions


def append_log(entry):
    entry = {'ts': int(time.time()), **entry}
    with open(LOG_FILE, 'a') as f:
        f.write(json.dumps(entry, ensure_ascii=False) + '\n')
    return entry


def read_log(limit=50):
    try:
        with open(LOG_FILE) as f:
            lines = f.readlines()[-limit:]
    except FileNotFoundError:
        return []
    out = []
    for line in lines:
        try:
            out.append(json.loads(line))
        except ValueError:
            pass
    return list(reversed(out))


async def run_shortcut(question, run_tool, cfg, entry=None):
    """Voice-command fast path. If cfg['voice_shortcuts'] is on and `question` confidently matches a
    shortcut, run it via run_tool(name, args) and return a short spoken/shown reply (also on failure,
    so a recognised command never silently turns into a Claude call). Returns None when there is no
    match or shortcuts are off, meaning: continue to Claude."""
    if not question or not cfg.get('voice_shortcuts', True):
        return None
    hit = voice_shortcuts.match(question)
    if hit is None:
        log.info('Even AI voice: %r matched no shortcut', question)
        return None
    action, args = hit
    log.info('Even AI voice: %r matched shortcut %s %s', question, action, args)
    label = f'{action} {args}' if args else action
    try:
        result = await run_tool(action, dict(args))
        reply, tag = str(result) or 'Done.', label
    except Exception as e:
        reply, tag = f"Sorry, I couldn't do that: {e}", f'{label} FAILED'
    if entry is not None:
        entry['actions'] = [f'shortcut: {tag}']
        entry['source'] = 'shortcut'
    log.info('Even AI shortcut: %s', tag)
    return reply
