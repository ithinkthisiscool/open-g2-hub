/// Voice command shortcuts — port of g2-hub/hub/voice_shortcuts.py: spoken phrases that run a
/// glasses tool directly, with no model round-trip ("hide display", "brightness up").
///
/// Forgiving about case, punctuation and politeness ("okay please", "could you", "thanks"),
/// but SAFE: after cleanup the WHOLE utterance must equal a known phrase (or the strict
/// "brightness N" pattern), so "close the window blinds" falls through to the model.
/// Parity with the Python matcher is tested on generated vectors.
library;

const int brightnessStep = 10;

const List<(String, Map<String, Object?>, List<String>)> _defaults = [
  ('close_display', {}, [
    'hide display', 'hide screen', 'close', 'close display', 'close screen', 'close app', 'close this', 'turn off display', //
    'turn off screen', 'display off', 'screen off', 'clear display', 'clear screen', 'dismiss', 'go away', 'exit',
    'turn display off', 'turn screen off', 'switch off display', 'switch off screen', 'switch display off',
    'switch screen off', 'shut display', 'shut off display', 'shut down display', 'disable display', 'blank display',
    'blank screen', 'stop', 'cancel', 'close it', 'hide it', 'hide window', 'close window', 'hide text',
    'hide glasses display',
  ]),
  ('show_dashboard', {}, [
    'show dashboard', 'open dashboard', 'dashboard', 'back to dashboard', 'show home', 'back home', 'go home', 'home', //
    'home screen',
  ]),
  ('show_weather', {}, ['show weather', 'weather', 'push weather', 'update weather', 'refresh weather']),
  ('adjust_brightness', {'delta': brightnessStep}, [
    'brightness up', 'brighter', 'increase brightness', 'raise brightness', 'turn brightness up', 'turn up brightness', //
    'make it brighter', 'brighten display', 'brighten', 'more brightness', 'increase brightness', 'brightness higher',
    'turn it up',
  ]),
  ('adjust_brightness', {'delta': -brightnessStep}, [
    'brightness down', 'dimmer', 'decrease brightness', 'lower brightness', 'reduce brightness', 'turn brightness down', //
    'turn down brightness', 'make it dimmer', 'dim display', 'dim', 'less brightness', 'brightness lower', 'darker',
    'make it darker', 'turn it down',
  ]),
  ('set_brightness', {'auto': true}, [
    'auto brightness', 'automatic brightness', 'brightness auto', 'brightness automatic', 'set brightness auto', //
    'set brightness automatic', 'set auto brightness',
  ]),
  ('set_silent_mode', {'on': true}, [
    'silent on', 'silent mode on', 'turn on silent mode', 'turn silent on', 'silent mode', 'do not disturb on', //
    'do not disturb', 'enable silent mode', 'silent mode on please', 'mute notifications', 'turn on do not disturb',
  ]),
  ('set_silent_mode', {'on': false}, [
    'silent off', 'silent mode off', 'turn off silent mode', 'turn silent off', 'do not disturb off', //
    'disable silent mode', 'unmute notifications', 'turn off do not disturb',
  ]),
];

const Set<String> _filler = {
  'please', 'the', 'a', 'my', 'hey', 'ok', 'okay', 'could', 'you', 'can', 'would', 'just', 'now', 'kindly', 'glasses', //
  'g2', 'to', 'for', 'me', 'thanks', 'thank', 'um', 'uh', 'erm', 'hmm', 'then', 'so', 'actually', 'alright', 'quickly',
  'assistant', 'claude', 'hello', 'hi', 'yeah', 'yes', 'i', 'id', 'want', 'need', 'lets', 'let', 'us', 'ill', 'right',
  'again', 'also',
};
const Set<String> _keep = {'turn', 'make', 'go', 'it', 'this', 'up', 'down', 'on', 'off'};
final RegExp _brightN = RegExp(r'^(?:set )?brightness (?:to |at )?(\d{1,3})(?: percent)?$');

/// A user-added shortcut (persisted in AI settings).
class CustomShortcut {
  CustomShortcut(this.phrase, this.action, [this.args = const {}]);
  final String phrase;
  final String action;
  final Map<String, Object?> args;
  Map<String, Object?> toJson() => {'phrase': phrase, 'action': action, 'args': args};
  factory CustomShortcut.fromJson(Map<String, Object?> j) => CustomShortcut(
      (j['phrase'] ?? '').toString(), (j['action'] ?? '').toString(), ((j['args'] as Map?) ?? const {}).cast<String, Object?>());
}

/// Lowercase, strip punctuation and filler words.
String normalize(String? text) {
  final t = (text ?? '').toLowerCase().replaceAll("'", '').replaceAll(RegExp(r'[^a-z0-9% ]+'), ' ');
  return t.split(' ').where((w) => w.isNotEmpty && (!_filler.contains(w) || _keep.contains(w))).join(' ');
}

Map<String, (String, Map<String, Object?>)> _table(List<CustomShortcut> custom) {
  final t = <String, (String, Map<String, Object?>)>{};
  for (final (action, args, phrases) in _defaults) {
    for (final p in phrases) {
      t[normalize(p)] = (action, Map.of(args));
    }
  }
  for (final c in custom) {
    t[normalize(c.phrase)] = (c.action, Map.of(c.args));
  }
  return t;
}

/// (action, args) when the utterance is confidently a known command, else null.
(String, Map<String, Object?>)? matchShortcut(String? transcript, {List<CustomShortcut> custom = const []}) {
  final norm = normalize(transcript);
  if (norm.isEmpty || norm.split(' ').length > 6) return null;
  final hit = _table(custom)[norm];
  if (hit != null) return hit;
  final m = _brightN.firstMatch(norm);
  if (m != null) {
    final n = int.parse(m.group(1)!);
    if (n >= 1 && n <= 50) return ('set_brightness', {'level': n});
  }
  return null;
}

/// For the settings screen: [(action, args, phrases)].
List<(String, Map<String, Object?>, List<String>)> shortcutList() => _defaults;
