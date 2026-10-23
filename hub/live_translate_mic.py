"""Continuous live translation from either the host device's microphone or the GLASSES' mic.

Two sources (LiveMicTranslator.start(source=...)):
  'device'  - sounddevice capture on the host (USB mic on the Pi, laptop mic), see below.
  'glasses' - the G2's own mic: LC3 packets on notify char 0x6402 (the Even AI audio pipeline),
              decoded with eai.Lc3Stream into the same 100 ms PCM blocks, then the same VAD/STT/
              translate/push path. See GlassesMicSource for the keep-alive / re-arm logic.

RE NOTES (official Even app 2.3.1-241, blutter dump under tools/even-watch/store/app/):
  * Translate has a per-user "voice input source" setting (enum VoiceInputSource: glasses | phone,
    even/pages/translate/page/settings/translation_settings_new_page.dart) stored as
    translation_audio_input_source. The app defaults to the PHONE mic and falls back phone ->
    "bluetooth" (glasses) on failure, and back to the phone mic when BLE drops
    (even/pages/translate/service/translation_service.dart, translation_recognizer_manager.dart).
  * The Translate CTRL OPEN message has a `useAudio` field (TranslateControl field 3,
    ProtoTranslateExt.sendStartTranslate); the g2 library leaves it unset. Its value/semantics for
    the glasses are NOT recoverable from the AOT dump (only a named-arg slot is visible).
  * Streaming is not a dedicated Translate opcode: the app only subscribes to the 0x6402 LC3 notify
    stream (BleG2CmdTransport._handleStreamResponse -> flutter_ezw_lc3 decodeLc3) and feeds it to an
    AudioManager/ASR (Soniox) pipeline. Continuity is client-side watchdog logic, not a protocol
    loop: "No audio data for ..." / "Recovering no audio input, audioAge=..." ->
    stop AudioManager, restart it, rebuild the recognizer; "Audio manager resumed but no audio
    data arrived, rebuilding audio and recognizer". EvenHub plugins use SID 0xE0 cmd 15 (AudioCtr)
    to open/close the glasses mic. There is no ENTER loop in Translate.
  * Not recoverable: exactly which BLE command the glasses-source Translate path sends to start the
    glasses mic (candidates: Translate OPEN useAudio=1, or EvenHub AudioCtr). No BLE capture of a
    Translate session exists in the repo. GlassesMicSource therefore rotates between the two
    known-working triggers (EvenHub audio control, Even AI CTRL ENTER) when the stream stalls.
    UNVERIFIED on real glasses.

Host-mic path:

    sounddevice capture (16 kHz mono, 100 ms blocks, blocking read in a worker thread)
      -> Segmenter (energy VAD: utterance ends after a short silence, or at a max length)
      -> queue -> STT (injected; the hub passes eai.transcribe_ex) -> translate (Claude)
      -> push to the glasses Translate app.

`sounddevice` (PortAudio) is an OPTIONAL dependency: `pip install -e '.[mic]'`, plus
`sudo apt install libportaudio2` and a microphone. Without them start() raises MicUnavailable
with a readable message; nothing here crashes the hub.
"""
import array
import asyncio
import inspect
import logging
import math
import time

SAMPLE_RATE = 16000
BLOCK_S = 0.1
BLOCK_SAMPLES = int(SAMPLE_RATE * BLOCK_S)
MIN_CONFIDENCE = 0.3

MIC_HINT = ("Live translation from the host microphone needs the optional 'sounddevice' package, PortAudio "
            "and a microphone: pip install -e '.[mic]'  and  sudo apt install libportaudio2  "
            "(then plug in a USB mic).")

log = logging.getLogger('g2hub.livemic')

try:                                    # optional dependency
    import sounddevice as sd
except Exception:                       # ImportError, or OSError when PortAudio is missing
    sd = None


class MicUnavailable(RuntimeError):
    pass


def mic_available():
    """True when sounddevice imports and at least one input device exists."""
    if sd is None:
        return False
    try:
        return any(d.get('max_input_channels', 0) > 0 for d in sd.query_devices())
    except Exception:
        return False


def mic_problem():
    """None if a mic can be used, else a friendly reason."""
    if sd is None:
        return MIC_HINT
    if not mic_available():
        return 'No microphone input device found. Plug in a USB mic (or check PortAudio/ALSA). ' + MIC_HINT
    return None


class SoundDeviceSource:
    """Blocking PCM16 mono reader. read() returns one block of bytes; call it from a thread."""

    def __init__(self, device=None):
        problem = mic_problem()
        if problem:
            raise MicUnavailable(problem)
        try:
            self._stream = sd.RawInputStream(samplerate=SAMPLE_RATE, channels=1, dtype='int16',
                                             blocksize=BLOCK_SAMPLES, device=device)
            self._stream.start()
        except Exception as e:
            raise MicUnavailable(f'Could not open the microphone: {e}') from e

    def read(self):
        data, _overflow = self._stream.read(BLOCK_SAMPLES)
        return bytes(data)

    def close(self):
        try:
            self._stream.stop()
            self._stream.close()
        except Exception:
            pass


GLASSES_HINT = ("Glasses-mic translation needs connected glasses and the LC3 audio decoder "
                "(run the hub with .venv/bin/python). You can use the device microphone instead.")


def glasses_problem(session, decoder_available):
    """None if the glasses mic can be used right now, else a friendly reason."""
    if session is None:
        return 'Glasses are not connected. ' + GLASSES_HINT
    if not decoder_available:
        return 'The LC3 audio decoder (lc3) is not installed. ' + GLASSES_HINT
    return None


class GlassesMicSource:
    """Async PCM16 source fed by the glasses' mic packets (session.audio_packets, 0x6402).

    aread() returns one ~100 ms block. Packets are LC3 (5 x 40 B frames = 800 samples); the left lens
    is preferred if it streams (cleaner), else the right. The stream only runs while "armed": if no
    packet arrives for `stall_s` (the glasses end their Even AI session / stop the mic on their own),
    aread() re-arms by rotating through `arm_fns` (each an async callable taking the session), with
    a short backoff. After `max_failures` consecutive failed re-arms it raises MicUnavailable so the
    translator reports the error instead of spinning. disarm_fns undo the arming on close().
    """

    def __init__(self, session, decoder_factory, arm_fns, disarm_fns=(), stall_s=3.0, max_failures=5,
                 report=None, clock=time.monotonic):
        self.session, self._new_decoder = session, decoder_factory
        self.arm_fns, self.disarm_fns = list(arm_fns), list(disarm_fns)
        self.stall_s, self.max_failures = stall_s, max_failures
        self._report, self._clock = report, clock
        self._decoders = {}
        self._buf = bytearray()
        self._rearm_idx = 0
        self.rearms = 0
        self._failures = 0
        self._last_packet = clock()
        self._arm_at = clock()
        self._got_audio_since_arm = False
        self._dead_rearms = 0

    def _say(self, msg, level='info'):
        if self._report:
            self._report(msg, level)

    async def arm(self, first=False):
        """Run the next arming strategy. Raises MicUnavailable on repeated failure."""
        fn = self.arm_fns[self._rearm_idx % len(self.arm_fns)]
        self._rearm_idx += 1
        if not first:
            self.rearms += 1
        try:
            await fn(self.session)
            self._failures = 0
        except Exception as e:
            self._failures += 1
            self._say(f'Glasses mic arm failed ({self._failures}/{self.max_failures}): {e}', 'warn')
            if first or self._failures >= self.max_failures:
                raise MicUnavailable(f'Could not start the glasses microphone: {e}. '
                                     'Use the device microphone instead.') from e
        self._last_packet = self._arm_at = self._clock()
        self._got_audio_since_arm = False

    def _decode(self, arm, packet):
        if arm not in self._decoders:
            self._decoders[arm] = self._new_decoder()
        return self._decoders[arm].decode(packet)

    async def aread(self):
        need = BLOCK_SAMPLES * 2
        while len(self._buf) < need:
            try:
                arm, packet = await asyncio.wait_for(self.session.audio_packets.get(), timeout=0.25)
            except asyncio.TimeoutError:
                if self._clock() - self._last_packet >= self.stall_s:
                    if self._failures == 0 and not self._got_audio_since_arm:
                        # the arm command SUCCEEDED but no audio ever came; don't re-arm forever
                        # (arm commands that raise are handled by _failures / arm())
                        self._dead_rearms += 1
                        if self._dead_rearms >= self.max_failures:
                            raise MicUnavailable('The glasses accepted the microphone commands but sent no audio. '
                                                 'Use the device microphone instead.')
                    self._say('Glasses mic stalled - re-arming', 'info')
                    # back off a little after repeated failures, never hammer the glasses
                    if self._failures:
                        await asyncio.sleep(min(2.0, 0.25 * self._failures))
                    await self.arm()
                continue
            self._last_packet = self._clock()
            self._got_audio_since_arm = True
            self._dead_rearms = 0
            if arm == 'R' and 'L' in self._decoders:
                continue                    # left lens is streaming; ignore the duplicate right one
            self._buf.extend(self._decode(arm, packet))
        block = bytes(self._buf[:need])
        del self._buf[:need]
        return block

    async def aclose(self):
        for fn in self.disarm_fns:
            try:
                await fn(self.session)
            except Exception as e:
                self._say(f'Glasses mic disarm step failed: {e}', 'warn')


def rms(pcm):
    a = array.array('h')
    a.frombytes(pcm[:len(pcm) - len(pcm) % 2])
    return math.sqrt(sum(x * x for x in a) / len(a)) if a else 0.0


class Segmenter:
    """Energy VAD. Learns the background level from the first ~0.5 s, calls a block speech when it
    is clearly louder, ends an utterance after `silence_s` of quiet (or at `max_s`). feed() takes
    one block and returns the finished utterance PCM, or None."""

    def __init__(self, silence_s=0.8, max_s=8.0, min_speech_s=0.3, min_level=300.0, preroll_s=0.3):
        self.silence_s, self.max_s, self.min_speech_s = silence_s, max_s, min_speech_s
        self.min_level, self.preroll = min_level, int(preroll_s / BLOCK_S)
        self.noise, self._calib = None, []
        self._pre, self._buf = [], []
        self._speech_s = self._quiet_s = self._len_s = 0.0

    def feed(self, block):
        dt = len(block) / 2 / SAMPLE_RATE
        level = rms(block)
        if self.noise is None:
            self._calib.append(level)
            if len(self._calib) * dt >= 0.5:
                self.noise = sorted(self._calib)[len(self._calib) // 2]
            return None
        speaking = level > max(self.min_level, self.noise * 3.0)
        if not self._buf:
            if speaking:
                self._buf = list(self._pre) + [block]
                self._speech_s, self._quiet_s, self._len_s = dt, 0.0, dt * len(self._buf)
            else:
                self._pre = (self._pre + [block])[-self.preroll:] if self.preroll else []
            return None
        self._buf.append(block)
        self._len_s += dt
        if speaking:
            self._speech_s += dt
            self._quiet_s = 0.0
        else:
            self._quiet_s += dt
        if self._quiet_s >= self.silence_s or self._len_s >= self.max_s:
            return self._finish()
        return None

    def _finish(self):
        pcm, speech = b''.join(self._buf), self._speech_s
        self._buf, self._pre = [], []
        self._speech_s = self._quiet_s = self._len_s = 0.0
        return pcm if speech >= self.min_speech_s else None


class LiveMicTranslator:
    """Background capture+translate loop. Everything external is injected so it is testable:
      source_factory() -> object with read()->bytes, close()
      stt(pcm) -> (text, confidence)         translate(text, src, dst) -> str (async)
      push(src, dst, original, translated)   async, raises if the glasses are unreachable
      report(message, level)                 optional log hook
    """

    def __init__(self, stt, translate, push, source_factory=SoundDeviceSource, spawn=None, report=None,
                 glasses_factory=None, glasses_check=None):
        """source_factory: host mic. glasses_factory: optional (sync or async) callable returning a
        GlassesMicSource-like object (aread/aclose). glasses_check() -> None or a reason string."""
        self.stt, self.translate, self.push = stt, translate, push
        self.source_factory, self._spawn, self._report = source_factory, spawn, report
        self.glasses_factory, self.glasses_check = glasses_factory, glasses_check
        self.src = self.dst = None
        self.source_name = None
        self._source = None
        self._task = None
        self._queue = None
        self.last_original = self.last_translated = ''
        self.last_error = self.last_push_error = ''
        self.count = 0

    def _say(self, msg, level='info'):
        if self._report:
            self._report(msg, level)

    def is_running(self):
        return self._task is not None and not self._task.done()

    def status(self):
        problem = self.glasses_problem()
        return {'running': self.is_running(), 'src': self.src, 'dst': self.dst, 'mic_available': mic_available(),
                'source': self.source_name, 'glasses_mic_available': problem is None,
                'glasses_mic_problem': problem or '', 'rearms': getattr(self._source, 'rearms', 0),
                'last_original': self.last_original, 'last_translated': self.last_translated,
                'last_error': self.last_error, 'last_push_error': self.last_push_error, 'utterances': self.count}

    def glasses_problem(self):
        if self.glasses_factory is None:
            return 'Glasses-mic translation is not configured.'
        if self.glasses_check is None:
            return None
        try:
            return self.glasses_check()
        except Exception as e:
            return f'Could not check the glasses mic: {e}'

    def default_source(self):
        return 'glasses' if self.glasses_problem() is None else 'device'

    async def start(self, src, dst, source='device'):
        """Open the mic and start the loop. source: 'device' (host mic) or 'glasses'.
        Raises MicUnavailable (nothing is left running) with a friendly message."""
        if source not in ('device', 'glasses'):
            raise ValueError(f'unknown source {source!r}')
        if self.is_running():
            await self.stop()
        if source == 'glasses':
            problem = self.glasses_problem()
            if problem:
                raise MicUnavailable(problem)
            source_obj = self.glasses_factory()
            if inspect.isawaitable(source_obj):
                source_obj = await source_obj   # arming happens here; raises MicUnavailable
        else:
            source_obj = self.source_factory()  # raises MicUnavailable with a friendly message
        self.source_name, self._source = source, source_obj
        source = source_obj
        self.src, self.dst = src, dst
        self.last_error = self.last_push_error = ''
        self._queue = asyncio.Queue(maxsize=4)
        coro = self._run(source)
        self._task = self._spawn(coro, name='live-translate-mic') if self._spawn else asyncio.ensure_future(coro)
        self._say(f'Live mic translate started ({src}>{dst}, {self.source_name} mic)', 'ok')

    async def stop(self):
        task, self._task = self._task, None
        if task is not None and not task.done():
            task.cancel()
            try:
                await asyncio.wait_for(asyncio.shield(task), 3)
            except (asyncio.CancelledError, asyncio.TimeoutError, Exception):
                pass
            self._say('Live mic translate stopped', 'info')

    async def _run(self, source):
        worker = asyncio.ensure_future(self._worker())
        seg = Segmenter()
        loop = asyncio.get_running_loop()
        try:
            while True:
                try:
                    if hasattr(source, 'aread'):
                        block = await source.aread()
                    else:
                        block = await loop.run_in_executor(None, source.read)
                except Exception as e:
                    self.last_error = f'Microphone read failed: {e}'
                    self._say(self.last_error, 'err')
                    return
                utt = seg.feed(block)
                if utt:
                    if self._queue.full():
                        self._queue.get_nowait()        # drop the oldest rather than fall behind
                    self._queue.put_nowait(utt)
        finally:
            worker.cancel()
            try:
                if hasattr(source, 'aclose'):
                    await asyncio.shield(source.aclose())
                else:
                    await asyncio.get_running_loop().run_in_executor(None, source.close)
            except BaseException:
                pass

    async def _worker(self):
        while True:
            pcm = await self._queue.get()
            try:
                await self.process(pcm)
            except asyncio.CancelledError:
                raise
            except Exception as e:      # one bad utterance never kills the loop
                self.last_error = str(e)
                self._say(f'Live mic translate: {e}', 'warn')

    async def process(self, pcm):
        """One utterance: STT -> translate -> push. Returns the translation or None if skipped."""
        text, conf = await self.stt(pcm)
        text = (text or '').strip()
        if not text or conf < MIN_CONFIDENCE:
            return None
        translated = await self.translate(text, self.src, self.dst)
        self.last_original, self.last_translated = text, translated
        self.count += 1
        self.last_error = ''
        try:
            await self.push(self.src, self.dst, text, translated)
            self.last_push_error = ''
        except Exception as e:
            self.last_push_error = f'push to glasses failed: {e}'
            self._say(f'Live mic translate: {self.last_push_error}', 'warn')
        self._say(f'Live mic {self.src}>{self.dst}: "{text}" -> "{translated}"', 'ok')
        return translated
