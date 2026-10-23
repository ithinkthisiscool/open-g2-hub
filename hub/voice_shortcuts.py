"""Voice command shortcuts: spoken phrases that run a glasses action directly, with no Claude round-trip.

match(transcript) -> (action, args) | None.  `action` is an AssistantTools tool name (see
hub/assistant_tools.py), so a matched shortcut runs through the same code path as Claude's tool calls.

Matching is forgiving about case, punctuation, polite/lead-in/trailing filler ("okay", "please",
"could you", "the", "now", "thanks", "I want to"), but SAFE: after that cleanup the WHOLE utterance must
equal a known phrase (or fit one of the few strict patterns), so the phrase may sit inside politeness
but never inside a longer, different request. "close the window blinds" or "what is the weather like in Paris" do NOT
match and fall through to Claude.
"""
import re

BRIGHTNESS_STEP = 10

# (action, args, [phrases]) — phrases are already normalised (lowercase, no filler words).
_DEFAULTS = [
    ('close_display', {}, ['hide display', 'hide screen', 'close', 'close display', 'close screen', 'close app',
                           'close this', 'turn off display', 'turn off screen', 'display off', 'screen off',
                           'clear display', 'clear screen', 'dismiss', 'go away', 'exit', 'turn display off', 'turn screen off',
                           'switch off display', 'switch off screen', 'switch display off', 'switch screen off',
                           'shut display', 'shut off display', 'shut down display', 'disable display',
                           'blank display', 'blank screen', 'stop', 'cancel', 'close it', 'hide it',
                           'hide window', 'close window', 'hide text', 'hide glasses display']),
    ('show_dashboard', {}, ['show dashboard', 'open dashboard', 'dashboard', 'back to dashboard', 'show home', 'back home', 'go home', 'home', 'home screen']),
    ('show_weather', {}, ['show weather', 'weather', 'push weather', 'update weather', 'refresh weather']),
    ('adjust_brightness', {'delta': BRIGHTNESS_STEP},
     ['brightness up', 'brighter', 'increase brightness', 'raise brightness', 'turn brightness up',
      'turn up brightness', 'make it brighter', 'brighten display', 'brighten', 'more brightness', 'increase brightness',
      'brightness higher', 'turn it up']),
    ('adjust_brightness', {'delta': -BRIGHTNESS_STEP},
     ['brightness down', 'dimmer', 'decrease brightness', 'lower brightness', 'reduce brightness',
      'turn brightness down', 'turn down brightness', 'make it dimmer', 'dim display', 'dim', 'less brightness', 'brightness lower', 'darker', 'make it darker',
      'turn it down']),
    ('set_brightness', {'auto': True}, ['auto brightness', 'automatic brightness', 'brightness auto',
                                        'brightness automatic', 'set brightness auto', 'set brightness automatic', 'set auto brightness']),
    ('set_silent_mode', {'on': True}, ['silent on', 'silent mode on', 'turn on silent mode', 'turn silent on',
                                       'silent mode', 'do not disturb on', 'do not disturb', 'enable silent mode', 'silent mode on please', 'mute notifications', 'turn on do not disturb']),
    ('set_silent_mode', {'on': False}, ['silent off', 'silent mode off', 'turn off silent mode', 'turn silent off',
                                        'do not disturb off', 'disable silent mode', 'unmute notifications', 'turn off do not disturb']),
]

_FILLER = {'please', 'the', 'a', 'my', 'hey', 'ok', 'okay', 'could', 'you', 'can', 'would', 'just', 'now',
           'kindly', 'glasses', 'g2', 'to', 'for', 'me', 'thanks', 'thank', 'um', 'uh', 'erm', 'hmm', 'then', 'so',
           'actually', 'alright', 'quickly', 'assistant', 'claude', 'hello', 'hi', 'yeah', 'yes', 'i', 'id',
           'want', 'need', 'lets', 'let', 'us', 'ill', 'right', 'again', 'also'}
_FILLER_KEEP_PHRASE = {'turn', 'make', 'go', 'it', 'this', 'up', 'down', 'on', 'off'}  # never dropped
_BRIGHT_N = re.compile(r'^(?:set )?brightness (?:to |at )?(\d{1,3})(?: percent)?$')

_custom = []   # [(phrase, action, args)] — optional user additions, see add_custom()


def normalize(text):
    """Lowercase, strip punctuation and filler words. Returns '' for empty input."""
    words = re.sub(r"[^a-z0-9% ]+", ' ', str(text or '').lower().replace("'", '')).split()
    return ' '.join(w for w in words if w not in _FILLER or w in _FILLER_KEEP_PHRASE)


def _table():
    t = {}
    for action, args, phrases in _DEFAULTS:
        for p in phrases:
            t[normalize(p)] = (action, dict(args))
    for phrase, action, args in _custom:
        t[normalize(phrase)] = (action, dict(args))
    return t


def match(transcript):
    """(action, args) when the utterance is confidently a known command, else None."""
    norm = normalize(transcript)
    if not norm or len(norm.split()) > 6:
        return None
    hit = _table().get(norm)
    if hit:
        return hit
    m = _BRIGHT_N.match(norm)
    if m:
        n = int(m.group(1))
        if 1 <= n <= 50:
            return 'set_brightness', {'level': n}
    return None


def add_custom(phrase, action, args=None):
    """Register an extra shortcut (in memory). `action` must be an AssistantTools tool name."""
    if not normalize(phrase) or not action:
        raise ValueError('phrase and action required')
    _custom.append((phrase, action, dict(args or {})))


def clear_custom():
    _custom.clear()


def shortcut_list():
    """For the UI/config: [{action, args, phrases}] (defaults first, then custom)."""
    out = [{'action': a, 'args': dict(args), 'phrases': list(ph)} for a, args, ph in _DEFAULTS]
    out += [{'action': a, 'args': dict(args), 'phrases': [p], 'custom': True} for p, a, args in _custom]
    return out
