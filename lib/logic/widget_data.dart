/// Custom widget data (graph values from text, JSON or CSV, optionally from a URL). Port of the
/// parsing half of g2-hub/hub/custom_widget.py; rendering is in services/image_widgets.dart.
library;

import 'dart:convert';

import 'pyfmt.dart';

const int minPoints = 2, maxPoints = 500;
const int maxBytes = 256 * 1024;
const Duration fetchTimeout = Duration(seconds: 8);
final RegExp _numSplit = RegExp(r'[,\s;]+');

double? _pyFloat(String tok) {
  final t = tok.trim();
  final l = t.toLowerCase();
  if (l == 'inf' || l == '+inf' || l == 'infinity' || l == '+infinity') return double.infinity;
  if (l == '-inf' || l == '-infinity') return double.negativeInfinity;
  if (l == 'nan' || l == '+nan' || l == '-nan') return double.nan;
  if (!RegExp(r'^[+-]?(\d+\.?\d*([eE][+-]?\d+)?|\.\d+([eE][+-]?\d+)?)$').hasMatch(t)) return null;
  return double.tryParse(t);
}

/// '1, 2 3\n4' → [1, 2, 3, 4] (last 500); FormatException on junk / non-finite.
List<double> parseValues(Object? text) {
  final out = <double>[];
  final s = (text == null || text == '' ? '' : text.toString()).trim();
  for (final tok in s.split(_numSplit)) {
    if (tok.isEmpty) continue;
    final f = _pyFloat(tok);
    final head = tok.length > 20 ? tok.substring(0, 20) : tok;
    if (f == null) throw FormatException("not a number: '$head'");
    if (!f.isFinite) throw FormatException("not a finite number: '$head'");
    out.add(f);
  }
  return out.length > maxPoints ? out.sublist(out.length - maxPoints) : out;
}

String _pyStr(Object v) => v is double ? pyFloatRepr(v) : v.toString();

List<double> cleanValues(Object? values) {
  if (values is String) return parseValues(values);
  if (values is! List) throw const FormatException('values must be a list of numbers or a string');
  return parseValues(values.where((v) => v is! bool).map((v) => _pyStr(v as Object)).join(' '));
}

/// JSON array / {values:[...]} / CSV (last numeric column) → values.
List<double> parsePayload(String text) {
  final t = text.trim();
  Object? data;
  var isJson = true;
  try {
    data = jsonDecode(t);
  } catch (_) {
    isJson = false;
  }
  if (data is Map) data = data['values'];
  if (isJson && data is List) {
    final nums = data.whereType<num>().toList();
    if (nums.isNotEmpty) return cleanValues(nums);
  } else if (!isJson || data == null) {
    final vals = <double>[];
    for (final row in const LineSplitter().convert(t)) {
      final cells = row.split(',');
      for (final cell in cells.reversed) {
        final f = _pyFloat(cell.trim());
        if (f != null) {
          vals.add(f);
          break;
        }
      }
    }
    if (vals.isNotEmpty) return cleanValues(vals);
  }
  throw const FormatException('no numbers found in the data');
}

/// Number label like the hub's _fmt: 1234 → '1234', 2.5 → '2.5', 3.0 → '3'.
String fmtNumber(double v) {
  if (v.abs() >= 1000) return pyFixed(v, 0);
  var s = pyFixed(v, 2);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '');
    s = s.replaceFirst(RegExp(r'\.$'), '');
  }
  return s.isEmpty ? '0' : s;
}
