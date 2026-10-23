/// Python html.unescape() for the cases news feeds use: numeric references (with the HTML5
/// invalid-codepoint table), and the common named entities (with or without ';' for the legacy
/// names). Unknown names are left as they are, as Python does.
library;

const Map<String, String> _named = {
  'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': ' ', 'copy': '©', //
  'reg': '®', 'trade': '™', 'hellip': '…', 'mdash': '—', 'ndash': '–',
  'lsquo': '‘', 'rsquo': '’', 'ldquo': '“', 'rdquo': '”', 'sbquo': '‚',
  'bdquo': '„', 'laquo': '«', 'raquo': '»', 'bull': '•', 'middot': '·',
  'deg': '°', 'euro': '€', 'pound': '£', 'yen': '¥', 'cent': '¢',
  'sect': '§', 'para': '¶', 'times': '×', 'divide': '÷', 'plusmn': '±',
  'frac12': '½', 'frac14': '¼', 'frac34': '¾', 'iexcl': '¡', 'iquest': '¿',
  'shy': '­', 'eacute': 'é', 'Eacute': 'É', 'egrave': 'è', 'agrave': 'à',
  'aacute': 'á', 'iacute': 'í', 'oacute': 'ó', 'uacute': 'ú', 'ntilde': 'ñ',
  'Ntilde': 'Ñ', 'ccedil': 'ç', 'uuml': 'ü', 'Uuml': 'Ü', 'ouml': 'ö',
  'Ouml': 'Ö', 'auml': 'ä', 'Auml': 'Ä', 'szlig': 'ß', 'ecirc': 'ê',
  'acirc': 'â', 'ocirc': 'ô', 'icirc': 'î', 'ucirc': 'û', 'aring': 'å',
  'oslash': 'ø', 'aelig': 'æ', 'thinsp': ' ', 'ensp': ' ', 'emsp': ' ',
  'zwj': '‍', 'zwnj': '‌', 'lrm': '‎', 'rlm': '‏', 'prime': '′',
  'Prime': '″', 'larr': '←', 'rarr': '→', 'uarr': '↑', 'darr': '↓',
  'micro': 'µ', 'ordm': 'º', 'ordf': 'ª', 'sup2': '²', 'sup3': '³',
};

/// Entities the HTML5 parser also accepts without a trailing ';' (subset of html5 table).
const Set<String> _legacy = {
  'amp', 'lt', 'gt', 'quot', 'nbsp', 'copy', 'reg', 'laquo', 'raquo', 'deg', 'pound', 'yen', 'cent', //
  'sect', 'para', 'times', 'divide', 'plusmn', 'frac12', 'frac14', 'frac34', 'iexcl', 'iquest', 'shy',
  'eacute', 'Eacute', 'egrave', 'agrave', 'aacute', 'iacute', 'oacute', 'uacute', 'ntilde', 'Ntilde',
  'ccedil', 'uuml', 'Uuml', 'ouml', 'Ouml', 'auml', 'Auml', 'szlig', 'ecirc', 'acirc', 'ocirc', 'icirc',
  'ucirc', 'aring', 'oslash', 'aelig', 'micro', 'ordm', 'ordf', 'sup2', 'sup3', 'middot',
};

const Map<int, String> _invalidCharrefs = {
  0x00: '�', 0x0d: '\r', 0x80: '€', 0x81: '\x81', 0x82: '‚', 0x83: 'ƒ', 0x84: '„', //
  0x85: '…', 0x86: '†', 0x87: '‡', 0x88: 'ˆ', 0x89: '‰', 0x8a: 'Š',
  0x8b: '‹', 0x8c: 'Œ', 0x8d: '\x8d', 0x8e: 'Ž', 0x8f: '\x8f', 0x90: '\x90', 0x91: '‘',
  0x92: '’', 0x93: '“', 0x94: '”', 0x95: '•', 0x96: '–', 0x97: '—',
  0x98: '˜', 0x99: '™', 0x9a: 'š', 0x9b: '›', 0x9c: 'œ', 0x9d: '\x9d',
  0x9e: 'ž', 0x9f: 'Ÿ',
};

bool _invalidCodepoint(int c) =>
    (c >= 0x1 && c <= 0x8) ||
    (c >= 0xE && c <= 0x1F) ||
    (c >= 0x7F && c <= 0x9F) ||
    (c >= 0xFDD0 && c <= 0xFDEF) ||
    c == 0xB ||
    (c & 0xFFFF) == 0xFFFE ||
    (c & 0xFFFF) == 0xFFFF;

final RegExp _charref = RegExp(r'&(#[0-9]+;?|#[xX][0-9a-fA-F]+;?|[^\t\n\f <&#;]{1,32};?)');

String _replace(String s) {
  if (s.startsWith('#')) {
    final n = s.substring(1, s.endsWith(';') ? s.length - 1 : s.length);
    final num = (n.startsWith('x') || n.startsWith('X')) ? int.parse(n.substring(1), radix: 16) : int.parse(n);
    final inv = _invalidCharrefs[num];
    if (inv != null) return inv;
    if ((num >= 0xD800 && num <= 0xDFFF) || num > 0x10FFFF) return '�';
    if (_invalidCodepoint(num)) return '';
    return String.fromCharCode(num);
  }
  if (s.endsWith(';')) {
    final v = _named[s.substring(0, s.length - 1)];
    if (v != null) return v;
  } else if (_legacy.contains(s)) {
    return _named[s]!;
  }
  for (var x = s.length - 1; x > 1; x--) {
    final head = s.substring(0, x);
    if (_legacy.contains(head)) return _named[head]! + s.substring(x);
  }
  return '&$s';
}

String htmlUnescape(String s) {
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(_charref, (m) => _replace(m[1]!));
}
