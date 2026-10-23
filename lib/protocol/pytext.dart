/// Python string semantics the protocol builders depend on, so text processing (slicing by
/// character, strip(), textwrap.wrap) gives byte-identical results to the Python library.
///
/// Python indexes strings by code point; Dart by UTF-16 unit. Everything here works on runes.
library;

/// Python's str.isspace() for one code point.
bool pyIsSpace(int c) =>
    (c >= 0x09 && c <= 0x0D) ||
    (c >= 0x1C && c <= 0x20) ||
    c == 0x85 ||
    c == 0xA0 ||
    c == 0x1680 ||
    (c >= 0x2000 && c <= 0x200A) ||
    c == 0x2028 ||
    c == 0x2029 ||
    c == 0x202F ||
    c == 0x205F ||
    c == 0x3000;

/// Python str.strip() (Unicode whitespace).
String pyStrip(String s) {
  final r = s.runes.toList();
  var a = 0;
  var b = r.length;
  while (a < b && pyIsSpace(r[a])) {
    a++;
  }
  while (b > a && pyIsSpace(r[b - 1])) {
    b--;
  }
  return String.fromCharCodes(r.sublist(a, b));
}

/// Python s[:n] (by code point).
String pyHead(String s, int n) {
  final r = s.runes.toList();
  return r.length <= n ? s : String.fromCharCodes(r.sublist(0, n < 0 ? 0 : n));
}

/// Python len(s).
int pyLen(String s) => s.runes.length;

/// Python str.expandtabs(tabsize).
String pyExpandTabs(String s, int tabsize) {
  final out = StringBuffer();
  var col = 0;
  for (final c in s.runes) {
    if (c == 0x09) {
      if (tabsize > 0) {
        final n = tabsize - (col % tabsize);
        out.write(' ' * n);
        col += n;
      }
    } else if (c == 0x0A || c == 0x0D) {
      out.writeCharCode(c);
      col = 0;
    } else {
      out.writeCharCode(c);
      col += 1;
    }
  }
  return out.toString();
}

// textwrap's _whitespace: '\t\n\x0b\x0c\r '.
bool _twWs(int c) => c == 0x09 || c == 0x0A || c == 0x0B || c == 0x0C || c == 0x0D || c == 0x20;

bool _allSpace(List<int> chunk) => chunk.every(pyIsSpace);

/// textwrap.wrap(text, width, break_on_hyphens=False) with every other option at its default
/// (expand_tabs, tabsize 8, replace_whitespace, drop_whitespace, break_long_words).
List<String> textwrapWrap(String text, int width) {
  if (width <= 0) throw ArgumentError('invalid width $width (must be > 0)');
  // _munge_whitespace: expandtabs(8), then each of \t\n\v\f\r -> ' '.
  final munged = pyExpandTabs(text, 8).runes.map((c) => _twWs(c) ? 0x20 : c).toList();
  // _split with wordsep_simple_re = '([\t\n\x0b\x0c\r ]+)', empty chunks dropped.
  final chunks = <List<int>>[];
  var cur = <int>[];
  bool? curWs;
  for (final c in munged) {
    final ws = _twWs(c);
    if (curWs != null && ws != curWs) {
      chunks.add(cur);
      cur = <int>[];
    }
    cur.add(c);
    curWs = ws;
  }
  if (cur.isNotEmpty) chunks.add(cur);

  final lines = <String>[];
  final rev = chunks.reversed.toList(); // stack: last element = next chunk
  while (rev.isNotEmpty) {
    final curLine = <List<int>>[];
    var curLen = 0;
    // First chunk on a line is whitespace: drop it, unless no line has started yet.
    if (_allSpace(rev.last) && lines.isNotEmpty) rev.removeLast();
    while (rev.isNotEmpty) {
      final l = rev.last.length;
      if (curLen + l <= width) {
        curLine.add(rev.removeLast());
        curLen += l;
      } else {
        break;
      }
    }
    if (rev.isNotEmpty && rev.last.length > width) {
      // _handle_long_word (break_long_words=True, break_on_hyphens=False)
      final spaceLeft = width < 1 ? 1 : width - curLen;
      if (spaceLeft > 0) {
        final chunk = rev.last;
        final end = spaceLeft > chunk.length ? chunk.length : spaceLeft;
        curLine.add(chunk.sublist(0, end));
        rev[rev.length - 1] = chunk.sublist(end);
      }
      curLen = curLine.fold(0, (a, c) => a + c.length);
    }
    if (curLine.isNotEmpty && _allSpace(curLine.last)) {
      curLen -= curLine.last.length;
      curLine.removeLast();
    }
    if (curLine.isNotEmpty) {
      lines.add(String.fromCharCodes(curLine.expand((c) => c)));
    }
  }
  return lines;
}
