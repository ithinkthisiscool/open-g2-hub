/// EvenHub app packages (.ehpk) and app.json manifests. Port of g2-hub/hub/evenhub_runtime.py
/// sections 1-2 (package format, manifest checks). Pure Dart; zstd via package:archive.
///
///   0 "EHPK"  4 u16 version  6 u16 kind (1 draft, 2 store-signed)  8 u32 first record offset
///   12 u32 record count  16 u32 extra header length; records `<type>` BA A9 BA:
///   E4 file (u32 clen, u32 size, 01 B7, u16 nlen, name, data)  E5 dir (BD AA, u16 nlen, name)
///   E3 footer (64 bytes; kind 1 = SHA-512 of everything before E3). Names and data are XORed with
///   "EVEN REALITIES"; data is zstd.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show ZstdDecoder;
import 'package:crypto/crypto.dart' show sha512;

class EhpkError implements Exception {
  EhpkError(this.message);
  final String message;
  @override
  String toString() => message;
}

final Uint8List ehpkMagic = Uint8List.fromList(utf8.encode('EHPK'));
final Uint8List ehpkKey = Uint8List.fromList(utf8.encode('EVEN REALITIES'));
const int kindDraft = 1, kindSigned = 2;
const List<int> _markFile = [0xe4, 0xba, 0xa9, 0xba];
const List<int> _markDir = [0xe5, 0xba, 0xa9, 0xba];
const List<int> _markEnd = [0xe3, 0xba, 0xa9, 0xba];
const List<int> _fileConst = [0x01, 0xb7];
const List<int> _dirConst = [0xbd, 0xaa];
const List<int> zstdMagic = [0x28, 0xb5, 0x2f, 0xfd];

const int maxPackageBytes = 16 * 1024 * 1024;
const int maxFileBytes = 16 * 1024 * 1024;
const int maxUnpackedBytes = 64 * 1024 * 1024;
const int maxFiles = 2000;
const int maxPathBytes = 512;
const int maxManifestBytes = 64 * 1024;

Uint8List xorKey(List<int> data) {
  final out = Uint8List(data.length);
  for (var i = 0; i < data.length; i++) {
    out[i] = data[i] ^ ehpkKey[i % ehpkKey.length];
  }
  return out;
}

bool _eq(List<int> a, int off, List<int> b) {
  if (off < 0 || off + b.length > a.length) return false;
  for (var i = 0; i < b.length; i++) {
    if (a[off + i] != b[i]) return false;
  }
  return true;
}

/// A zstd frame storing [data] uncompressed (raw blocks), as the hub's packer writes.
Uint8List zstdRawFrame(List<int> data) {
  final out = BytesBuilder()..add(zstdMagic)..addByte(0xA0);
  final sz = ByteData(4)..setUint32(0, data.length, Endian.little);
  out.add(sz.buffer.asUint8List());
  const block = 128 * 1024;
  void hdr(int v) => out.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF]);
  if (data.isEmpty) {
    hdr(1);
    return out.toBytes();
  }
  for (var i = 0; i < data.length; i += block) {
    final end = i + block > data.length ? data.length : i + block;
    hdr(((end - i) << 3) | (end >= data.length ? 1 : 0));
    out.add(data.sublist(i, end));
  }
  return out.toBytes();
}

/// Decompress one zstd frame, never past [limit] bytes.
Uint8List zstdDecompress(List<int> frame, {int limit = maxFileBytes}) {
  if (frame.length < 5 || !_eq(frame, 0, zstdMagic)) throw EhpkError('not a zstd frame');
  try {
    final out = ZstdDecoder().decodeBytes(frame, throwOnError: true, maxOutputSize: limit);
    return out;
  } catch (e) {
    if (e is EhpkError) rethrow;
    throw EhpkError('zstd: $e');
  }
}

class Ehpk {
  Ehpk(this.kind, this.files, {this.dirs = const [], this.headerPackageId = '', Uint8List? footer, this.hashOk})
      : footer = footer ?? Uint8List(0);
  final int kind;
  final Map<String, Uint8List> files;
  final List<String> dirs;
  final String headerPackageId;
  final Uint8List footer;
  final bool? hashOk;

  Map<String, Object?> get manifest {
    final raw = files['app.json'];
    if (raw == null) throw EhpkError('app.json not found');
    return parseManifest(raw);
  }

  /// {path relative to dist/: bytes}.
  Map<String, Uint8List> distFiles() => {
        for (final e in files.entries)
          if (e.key.startsWith('dist/')) e.key.substring(5): e.value
      };

  String get kindLabel => kind == kindDraft
      ? (hashOk == true ? 'draft (SHA-512 ok)' : 'draft (no footer)')
      : 'store-signed (signature NOT verified)';
}

final RegExp _unsafeChars = RegExp(r'[\x00-\x1f\x7f\\:]');

void checkMemberName(String name) {
  if (name.isEmpty ||
      name.startsWith('/') ||
      _unsafeChars.hasMatch(name) ||
      utf8.encode(name).length > maxPathBytes ||
      name.split('/').any((p) => p == '..' || p == '.' || p.isEmpty)) {
    throw EhpkError('unsafe path in package: $name');
  }
}

int _u16(List<int> d, int o) => d[o] | (d[o + 1] << 8);
int _u32(List<int> d, int o) => d[o] | (d[o + 1] << 8) | (d[o + 2] << 16) | (d[o + 3] << 24);

/// Parse .ehpk bytes (untrusted: sizes, names and counts are bounded).
Ehpk readEhpk(List<int> data, {bool verify = true}) {
  if (data.length > maxPackageBytes) throw EhpkError('package larger than ${maxPackageBytes ~/ (1024 * 1024)} MB');
  if (data.length < 20 || !_eq(data, 0, ehpkMagic)) throw EhpkError('not an EHPK file (bad magic)');
  try {
    return _readEhpk(data, verify);
  } on RangeError catch (e) {
    throw EhpkError('malformed package: $e');
  } on FormatException catch (e) {
    throw EhpkError('malformed package: $e');
  }
}

Ehpk _readEhpk(List<int> data, bool verify) {
  final kind = _u16(data, 6);
  final first = _u32(data, 8), count = _u32(data, 12);
  final maxFirst = data.length < 20 + 4096 ? data.length : 20 + 4096;
  if (first < 20 || first > maxFirst) throw EhpkError('bad first-record offset $first');
  if (count > maxFiles) throw EhpkError('too many records ($count > $maxFiles)');
  if (kind == kindDraft && verify && data.length >= 68 && _eq(data, data.length - 68, _markEnd)) {
    final digest = sha512.convert(data.sublist(0, data.length - 68)).bytes;
    if (!_eq(data, data.length - 64, digest)) throw EhpkError('SHA-512 footer mismatch (corrupt draft package)');
  }
  final headerPid = first > 20 ? utf8.decode(xorKey(data.sublist(20, first)), allowMalformed: true) : '';
  final files = <String, Uint8List>{};
  final dirs = <String>[];
  var p = first, n = 0, total = 0;
  Uint8List footer = Uint8List(0);
  bool? hashOk;
  while (p < data.length) {
    if (n >= maxFiles) throw EhpkError('too many records (> $maxFiles)');
    if (_eq(data, p, _markFile)) {
      final clen = _u32(data, p + 4), size = _u32(data, p + 8), nlen = _u16(data, p + 14);
      if (p + 16 + nlen + clen > data.length) throw EhpkError('truncated file record');
      final name = utf8.decode(xorKey(data.sublist(p + 16, p + 16 + nlen)));
      checkMemberName(name);
      if (files.containsKey(name)) throw EhpkError('duplicate entry $name');
      if (size > maxFileBytes) throw EhpkError('$name: $size bytes unpacked (limit $maxFileBytes)');
      total += size;
      if (total > maxUnpackedBytes) throw EhpkError('package unpacks to more than ${maxUnpackedBytes ~/ (1024 * 1024)} MB');
      final body = xorKey(data.sublist(p + 16 + nlen, p + 16 + nlen + clen));
      final content = zstdDecompress(body, limit: size);
      if (content.length != size) throw EhpkError('$name: size ${content.length} != header $size');
      files[name] = content;
      p += 16 + nlen + clen;
      n++;
    } else if (_eq(data, p, _markDir)) {
      final nlen = _u16(data, p + 6);
      if (p + 8 + nlen > data.length) throw EhpkError('truncated directory record');
      final d = utf8.decode(xorKey(data.sublist(p + 8, p + 8 + nlen)));
      checkMemberName(d);
      dirs.add(d);
      p += 8 + nlen;
      n++;
    } else if (_eq(data, p, _markEnd)) {
      footer = Uint8List.fromList(data.sublist(p + 4, p + 68 > data.length ? data.length : p + 68));
      if (kind == kindDraft) {
        hashOk = _eq(sha512.convert(data.sublist(0, p)).bytes, 0, footer) && footer.length == 64;
        if (verify && !hashOk) throw EhpkError('SHA-512 footer mismatch (corrupt draft package)');
      }
      break;
    } else {
      final mark = data.sublist(p, p + 4 > data.length ? data.length : p + 4).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      throw EhpkError('unknown record marker $mark at $p');
    }
  }
  if (count != 0 && n != count) throw EhpkError('record count $n != header $count');
  return Ehpk(kind, files, dirs: dirs, headerPackageId: headerPid, footer: footer, hashOk: hashOk);
}

/// Build a kind-1 (draft) package with raw zstd frames (deterministic; matches the hub's
/// write_ehpk(compress='raw') byte for byte).
Uint8List writeEhpk(Object manifest, Map<String, List<int>> distFiles) {
  final mbytes = manifest is Map ? utf8.encode(jsonEncode(manifest)) : manifest as List<int>;
  final records = <List<int>>[];
  List<int> u16(int v) => [v & 0xFF, (v >> 8) & 0xFF];
  List<int> u32(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];
  List<int> fileRec(String name, List<int> content) {
    checkMemberName(name);
    final nb = xorKey(utf8.encode(name));
    final comp = xorKey(zstdRawFrame(content));
    return [..._markFile, ...u32(comp.length), ...u32(content.length), ..._fileConst, ...u16(nb.length), ...nb, ...comp];
  }

  List<int> dirRec(String name) {
    final nb = xorKey(utf8.encode(name));
    return [..._markDir, ..._dirConst, ...u16(nb.length), ...nb];
  }

  records.add(fileRec('app.json', mbytes));
  records.add(dirRec('dist'));
  final seen = {'dist'};
  final names = distFiles.keys.toList()..sort(_pyStrCompare);
  for (final rel in names) {
    final parts = rel.split('/');
    for (var i = 1; i < parts.length; i++) {
      final d = 'dist/${parts.sublist(0, i).join('/')}';
      if (seen.add(d)) records.add(dirRec(d));
    }
    records.add(fileRec('dist/$rel', distFiles[rel]!));
  }
  final body = BytesBuilder()
    ..add(ehpkMagic)
    ..add(u16(1))
    ..add(u16(kindDraft))
    ..add(u32(20))
    ..add(u32(records.length))
    ..add(u32(0));
  for (final r in records) {
    body.add(r);
  }
  final b = body.toBytes();
  return Uint8List.fromList([...b, ..._markEnd, ...sha512.convert(b).bytes]);
}

/// Python sorts str by code point.
int _pyStrCompare(String a, String b) {
  final ra = a.runes.toList(), rb = b.runes.toList();
  for (var i = 0; i < ra.length && i < rb.length; i++) {
    if (ra[i] != rb[i]) return ra[i].compareTo(rb[i]);
  }
  return ra.length.compareTo(rb.length);
}

// ── app.json ──────────────────────────────────────────────────────────────────────────────
final RegExp packageIdRe = RegExp(r'^[a-z][a-z0-9]*(\.[a-z][a-z0-9]*)+$');
final RegExp versionRe = RegExp(r'^\d+\.\d+\.\d+$');
const Set<String> permissionNames = {'network', 'location', 'g2-microphone', 'phone-microphone', 'album', 'camera'};
const Set<String> languages = {'en', 'de', 'fr', 'es', 'it', 'zh', 'ja', 'ko'};
final RegExp safePackageIdRe = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]*(\.[A-Za-z0-9][A-Za-z0-9_-]*)+$');
final RegExp _ctrlRe = RegExp(r'[\x00-\x1f\x7f]');

Map<String, Object?> parseManifest(List<int> raw) {
  if (raw.length > maxManifestBytes) throw EhpkError('app.json larger than $maxManifestBytes bytes');
  Object? m;
  try {
    m = jsonDecode(utf8.decode(raw));
  } catch (e) {
    throw EhpkError('app.json is not valid JSON: $e');
  }
  if (m is! Map) throw EhpkError('app.json must be a JSON object');
  return m.cast<String, Object?>();
}

/// Hard checks before anything is written (safe package id + entrypoint, string name/version).
void checkManifest(Map<String, Object?> m) {
  final pid = m['package_id'];
  if (pid is! String || pid.length > 128 || !safePackageIdRe.hasMatch(pid) || pid.endsWith('.installing') || pid.endsWith('.backup')) {
    throw EhpkError('bad package_id ${pid.toString().substring(0, pid.toString().length.clamp(0, 80))} (expected something like com.example.app)');
  }
  final entry = m.containsKey('entrypoint') ? m['entrypoint'] : 'index.html';
  if (entry is! String) throw EhpkError('entrypoint must be a string');
  checkMemberName(entry.isEmpty ? 'index.html' : entry);
  for (final k in ['name', 'version']) {
    if (m[k] != null && m[k] is! String) throw EhpkError('$k must be a string');
  }
}

String cleanText(Object? value, int limit) {
  final s = (value ?? '').toString().replaceAll(_ctrlRe, '');
  final r = s.runes.toList();
  return r.length > limit ? String.fromCharCodes(r.take(limit)) : s;
}

/// Both permission shapes → [{name, desc, whitelist?}].
List<Map<String, Object?>> normalizePermissions(Object? perms) {
  if (perms is Map) {
    return [
      for (final e in perms.entries)
        {'name': e.key, 'desc': '', if (e.value is List) 'whitelist': e.value}
    ];
  }
  return [if (perms is List) for (final p in perms) if (p is Map) p.cast<String, Object?>()];
}

List<Map<String, Object?>> displayPermissions(Object? perms) => [
      for (final p in normalizePermissions(perms).take(20))
        {
          'name': cleanText(p['name'], 40),
          'desc': cleanText(p['desc'], 300),
          if (p['whitelist'] is List) 'whitelist': [for (final h in (p['whitelist'] as List).take(20)) cleanText(h, 200)],
        }
    ];

/// Soft schema problems (store packages may fail some; they still run).
List<String> validateManifest(Map<String, Object?> m) {
  final problems = <String>[];
  final pid = m['package_id'] ?? '';
  if (pid is! String || !packageIdRe.hasMatch(pid)) {
    problems.add("package_id ${pyRepr(cleanText(pyStr(pid), 80))} must look like com.example.app (lowercase, no dashes)");
  }
  if (m['edition'] != '202601') problems.add('edition must be "202601"');
  final name = m['name'] ?? '';
  if (name is! String || name.isEmpty || name.length > 20) problems.add('name must be 1-20 characters');
  final version = m['version'];
  if (version is! String || !versionRe.hasMatch(version)) problems.add('version must be x.y.z');
  final ep = m['entrypoint'];
  if (ep == null || ep == '' || ep == false) problems.add('entrypoint is required (e.g. index.html)');
  if (m['min_sdk_version'] is! String) problems.add('min_sdk_version (string) is required');
  final perms = m['permissions'];
  if (perms is! List) {
    problems.add('permissions must be a list of {name, desc}');
  } else {
    for (final p in perms.take(50)) {
      if (p is! Map || p['name'] is! String || !permissionNames.contains(p['name'])) {
        problems.add('unknown permission ${pyRepr(cleanText(pyStr(p), 80))}');
      } else {
        final d = p['desc'];
        if (d is! String || d.isEmpty || d.length > 300) problems.add('permission ${p['name']}: desc must be 1-300 characters');
      }
    }
  }
  final langs = m['supported_languages'];
  if (langs is! List || langs.isEmpty || !langs.every((x) => x is String) || !langs.every(languages.contains)) {
    problems.add('supported_languages must be a non-empty subset of ${pyRepr(languages.toList()..sort())}');
  }
  if ((m['tagline'] ?? '').toString().length > 50) problems.add('tagline must be 50 characters or fewer');
  if ((m['description'] ?? '').toString().length > 1024) problems.add('description must be 1024 characters or fewer');
  return problems;
}

bool hasNetworkPermission(Map<String, Object?> app) =>
    ((app['permissions'] as List?) ?? const []).any((p) => p is Map && p['name'] == 'network');

/// Python repr() of JSON-like values (str, num, bool, None, list, dict).
String pyRepr(Object? v) {
  if (v == null) return 'None';
  if (v is bool) return v ? 'True' : 'False';
  if (v is String) {
    final useDouble = v.contains("'") && !v.contains('"');
    final q = useDouble ? '"' : "'";
    final b = StringBuffer(q);
    for (final c in v.runes) {
      if (c == 0x5C) {
        b.write(r'\\');
      } else if (String.fromCharCode(c) == q) {
        b.write('\\$q');
      } else if (c == 0x0A) {
        b.write(r'\n');
      } else if (c == 0x0D) {
        b.write(r'\r');
      } else if (c == 0x09) {
        b.write(r'\t');
      } else if (c < 0x20 || c == 0x7F) {
        b.write('\\x${c.toRadixString(16).padLeft(2, '0')}');
      } else {
        b.writeCharCode(c);
      }
    }
    b.write(q);
    return b.toString();
  }
  if (v is List) return '[${v.map(pyRepr).join(', ')}]';
  if (v is Map) return '{${v.entries.map((e) => '${pyRepr(e.key)}: ${pyRepr(e.value)}').join(', ')}}';
  if (v is double && v == v.truncateToDouble() && v.abs() < 1e16) return '${v.toInt()}.0';
  return '$v';
}

/// Python str(): strings as-is, everything else repr().
String pyStr(Object? v) => v is String ? v : pyRepr(v);
