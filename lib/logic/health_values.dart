/// Health card values typed by the user (g2-hub/hub/routes/health.py clean + defaults).
library;

/// name → (min, max, integer?)
const Map<String, (num, num, bool)> healthFields = {
  'steps': (0, 200000, true), 'step_goal': (0, 200000, true), 'calories': (0, 20000, true), //
  'calorie_goal': (0, 20000, true), 'sleep_minutes': (0, 1440, true), 'sleep': (0, 100, false),
  'heart_rate': (20, 250, true), 'heart_rate_avg': (20, 250, true), 'spo2': (50, 100, true),
  'spo2_avg': (50, 100, true),
};
const Map<String, num> healthDefaults = {
  'steps': 6500, 'step_goal': 10000, 'calories': 1800, 'calorie_goal': 2200, 'sleep_minutes': 450, //
  'sleep': 82, 'heart_rate': 68, 'heart_rate_avg': 64, 'spo2': 98, 'spo2_avg': 97,
};

/// Validate posted values; blank = leave the metric out. FormatException on bad input.
Map<String, num> cleanHealth(Map<String, Object?> data) {
  final out = <String, num>{};
  for (final e in healthFields.entries) {
    final v = data[e.key];
    if (v == null || v == '') continue;
    final (lo, hi, integer) = e.value;
    num n;
    if (v is num && v is! bool) {
      n = integer ? v.toInt() : v.toDouble();
    } else {
      final s = v.toString().trim();
      final p = integer ? int.tryParse(s) : double.tryParse(s);
      if (p == null) throw FormatException('${e.key} must be a number');
      n = p;
    }
    if (n < lo || n > hi) throw FormatException('${e.key} must be $lo-$hi');
    out[e.key] = n;
  }
  if (out.isEmpty) throw const FormatException('enter at least one value');
  return out;
}
