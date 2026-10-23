/// Downloads, verifies and deletes on-device model files (LLM weights and speech models).
///
///  * Resumable: data goes to `<file>.part`; a later download continues it with an HTTP
///    `Range` request (a server that ignores Range restarts it from zero).
///  * Verified: SHA-256 over the whole file (the part already on disk is re-hashed before
///    resuming) must equal the hash Hugging Face publishes for the pinned file; a mismatch
///    deletes the part file and fails.
///  * Wi-Fi only by default, and refused up front when free storage is short.
///  * Custom GGUF models can be imported from a file or added by URL (power users); their
///    hash is computed on import, or taken from Hugging Face's `X-Linked-Etag` for a
///    huggingface.co URL, or given by the user.
///
/// Files live in the app's private support directory: `<root>/<model id>/<file name>`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../engines.dart';
import '../providers/llm.dart' show AiError;
import 'device_info.dart';
import 'local_catalog.dart';

/// Extra free space kept on top of the download (the OS and the app need room too).
const int storageMargin = 200 << 20;

class LocalModelStore implements ModelDownloadManager {
  LocalModelStore({
    required this.root,
    http.Client Function()? client,
    Future<bool> Function()? onWifi,
    Future<int?> Function(String path)? freeSpace,
    List<LocalModelSpec>? catalog,
  })  : _client = client ?? http.Client.new,
        _onWifi = onWifi ?? onUnmeteredNetwork,
        _freeSpace = freeSpace ?? freeDiskBytes,
        _catalog = catalog ?? [...llmCatalog, ...sttCatalog];

  /// The model directory (app-private support dir in the app).
  final Future<Directory> Function() root;
  final http.Client Function() _client;
  final Future<bool> Function() _onWifi;
  final Future<int?> Function(String path) _freeSpace;
  final List<LocalModelSpec> _catalog;
  List<LocalModelSpec>? _custom;
  final Map<String, ModelStatus> _active = {};
  final Set<String> _cancel = {};
  final Map<String, Future<void>> _runs = {};

  /// Fires whenever a model's state changes (download progress, done, deleted).
  final StreamController<String> changes = StreamController<String>.broadcast();

  // ── catalog ────────────────────────────────────────────────────────────────────────────
  Future<Directory> get rootDir async {
    final d = await root();
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<File> get _manifest async => File('${(await rootDir).path}/custom_models.json');

  Future<List<LocalModelSpec>> customModels() async {
    if (_custom != null) return _custom!;
    try {
      final f = await _manifest;
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString()) as List;
        return _custom = [for (final m in j) if (m is Map) LocalModelSpec.fromJson(m.cast<String, Object?>())];
      }
    } catch (_) {/* corrupt manifest: start empty */}
    return _custom = [];
  }

  Future<void> _saveCustom() async =>
      (await _manifest).writeAsString(jsonEncode([for (final m in _custom ?? const <LocalModelSpec>[]) m.toJson()]));

  Future<List<LocalModelSpec>> specs({LocalKind? kind}) async =>
      [..._catalog, ...await customModels()].where((m) => kind == null || m.kind == kind).toList();

  Future<LocalModelSpec?> spec(String id) async => (await specs()).where((m) => m.id == id).firstOrNull;

  @override
  Future<List<LocalModel>> available() async => [
        for (final m in await specs())
          LocalModel(id: m.id, label: m.label, sizeBytes: m.sizeBytes, minRamBytes: m.minRamBytes, languages: m.languages)
      ];

  Future<String> dirOf(String id) async => '${(await rootDir).path}/${_safe(id)}';
  static String _safe(String id) => id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  /// Path of [file] of model [id] (exists only once downloaded and verified).
  Future<String> pathOf(String id, ModelFile file) async => '${await dirOf(id)}/${_safe(file.name)}';

  // ── status ─────────────────────────────────────────────────────────────────────────────
  @override
  Future<ModelStatus> status(String modelId) async {
    final a = _active[modelId];
    if (a != null) return a;
    final m = await spec(modelId);
    if (m == null) return const ModelStatus(ModelState.notDownloaded, error: 'Unknown model');
    var have = 0;
    var complete = true;
    for (final f in m.files) {
      final p = await pathOf(modelId, f);
      if (await File(p).exists()) {
        have += f.sizeBytes;
      } else {
        complete = false;
        final part = File('$p.part');
        if (await part.exists()) have += await part.length();
      }
    }
    if (complete) return const ModelStatus(ModelState.ready, progress: 1);
    return ModelStatus(ModelState.notDownloaded, progress: m.sizeBytes == 0 ? 0 : (have / m.sizeBytes).clamp(0, 1));
  }

  Future<bool> isReady(String id) async => (await status(id)).state == ModelState.ready;

  /// Stop a running download (the part file is kept, so it resumes later).
  void cancel(String id) => _cancel.add(id);

  // ── download ───────────────────────────────────────────────────────────────────────────
  @override
  Stream<ModelStatus> download(String modelId, {bool wifiOnly = true}) {
    final running = _active[modelId];
    final run = _runs[modelId];
    if (running != null && run != null && _cancel.contains(modelId)) {
      // Pause pressed, then download/resume again before the running transfer noticed: resume
      // once it has stopped (otherwise the resume was swallowed and the pause still won).
      final out = StreamController<ModelStatus>();
      out.add(running);
      unawaited(run.whenComplete(() => out.addStream(download(modelId, wifiOnly: wifiOnly)).whenComplete(out.close)));
      return out.stream;
    }
    if (running != null) return Stream.value(running); // already downloading: watch [changes]
    _active[modelId] = const ModelStatus(ModelState.downloading);
    final out = StreamController<ModelStatus>();
    void emit(ModelStatus s) {
      if (s.state == ModelState.downloading) {
        _active[modelId] = s;
      } else {
        _active.remove(modelId);
      }
      if (!out.isClosed) out.add(s);
      changes.add(modelId);
    }

    final done = () async {
      try {
        await _download(modelId, wifiOnly, emit);
      } catch (e) {
        emit(ModelStatus(ModelState.failed, error: describeDownloadError(e)));
      } finally {
        _cancel.remove(modelId);
        _active.remove(modelId);
        _runs.removeWhere((k, _) => k == modelId);
        await out.close();
      }
    }();
    _runs[modelId] = done;
    return out.stream;
  }

  Future<void> _download(String id, bool wifiOnly, void Function(ModelStatus) emit) async {
    final m = await spec(id);
    if (m == null) throw AiError('Unknown model "$id"');
    _cancel.remove(id);
    emit(const ModelStatus(ModelState.downloading));
    if (wifiOnly && !await _onWifi()) {
      throw AiError('Not on Wi-Fi. "Download on Wi-Fi only" is on; connect to Wi-Fi or turn it off.');
    }
    final dir = Directory(await dirOf(id));
    await dir.create(recursive: true);

    // Storage: what is still missing, plus a margin.
    var have = 0;
    for (final f in m.files) {
      final p = await pathOf(id, f);
      if (await File(p).exists()) {
        have += f.sizeBytes;
      } else if (await File('$p.part').exists()) {
        have += await File('$p.part').length();
      }
    }
    final missing = (m.sizeBytes - have).clamp(0, m.sizeBytes);
    final free = await _freeSpace(dir.path);
    if (free != null && free < missing + storageMargin) {
      throw AiError('Not enough storage: ${m.label} needs ${formatBytes(missing + storageMargin)} free '
          '(${formatBytes(missing)} + room for the phone), only ${formatBytes(free)} is free.');
    }

    final client = _client();
    try {
      var done = 0;
      for (final f in m.files) {
        final path = await pathOf(id, f);
        if (await File(path).exists()) {
          done += f.sizeBytes;
          continue;
        }
        await _fetch(id, f, path, client, (n) {
          final total = m.sizeBytes;
          emit(ModelStatus(ModelState.downloading, progress: total == 0 ? 0 : ((done + n) / total).clamp(0, 1)));
        });
        done += f.sizeBytes;
      }
    } finally {
      client.close();
    }
    emit(const ModelStatus(ModelState.ready, progress: 1));
  }

  Future<void> _fetch(String id, ModelFile f, String path, http.Client client, void Function(int bytes) progress) async {
    final part = File('$path.part');
    var offset = await part.exists() ? await part.length() : 0;
    if (f.sizeBytes > 0 && offset > f.sizeBytes) {
      await part.delete();
      offset = 0;
    }

    final req = http.Request('GET', Uri.parse(f.url));
    if (offset > 0) req.headers['range'] = 'bytes=$offset-';
    final res = await client.send(req).timeout(const Duration(seconds: 30));
    IOSink sink;
    if (res.statusCode == 206 && offset > 0) {
      sink = part.openWrite(mode: FileMode.append);
    } else if (res.statusCode == 416 && offset > 0) {
      // Range not satisfiable: the part file is already complete.
      await res.stream.drain<void>();
      sink = part.openWrite(mode: FileMode.append);
    } else if (res.statusCode == 200) {
      offset = 0; // the server ignored Range: start over
      sink = part.openWrite();
    } else {
      await res.stream.drain<void>();
      throw AiError('Download failed: HTTP ${res.statusCode} for ${f.name}');
    }

    // Hash the bytes already on disk, then the new ones as they arrive.
    final digest = _DigestSink();
    final hasher = sha256.startChunkedConversion(digest);
    if (offset > 0) {
      await for (final chunk in part.openRead(0, offset)) {
        hasher.add(chunk);
      }
    }
    var received = offset;
    var lastReport = -1;
    try {
      await for (final chunk in res.stream.timeout(const Duration(seconds: 60))) {
        if (_cancel.contains(id)) throw AiError('Download paused');
        sink.add(chunk);
        hasher.add(chunk);
        received += chunk.length;
        if (received - lastReport >= (1 << 20)) {
          lastReport = received;
          progress(received);
        }
      }
    } on TimeoutException {
      throw AiError('Download stalled; it will resume from ${formatBytes(received)} next time');
    } finally {
      // A write error (disk full) surfaces here; close the file either way.
      Object? writeError;
      try {
        await sink.flush();
      } catch (e) {
        writeError = e;
      }
      try {
        await sink.close();
      } catch (e) {
        writeError ??= e;
      }
      if (writeError != null) throw writeError;
    }
    hasher.close();
    progress(received);

    if (f.sizeBytes > 0 && received != f.sizeBytes) {
      throw AiError('Download incomplete (${formatBytes(received)} of ${formatBytes(f.sizeBytes)}); try again to resume');
    }
    final got = digest.value.toString();
    if (f.sha256.isNotEmpty && got != f.sha256) {
      await part.delete();
      throw AiError('Checksum mismatch for ${f.name}: the file was corrupted or changed on the server. It was deleted.');
    }
    await part.rename(path);
  }

  // ── delete ─────────────────────────────────────────────────────────────────────────────
  @override
  Future<void> delete(String modelId) async {
    cancel(modelId);
    final d = Directory(await dirOf(modelId));
    if (await d.exists()) await d.delete(recursive: true);
    final custom = await customModels();
    if (custom.any((m) => m.id == modelId)) {
      custom.removeWhere((m) => m.id == modelId);
      await _saveCustom();
    }
    changes.add(modelId);
  }

  /// Bytes used by all model files (downloaded and partial).
  Future<int> usedBytes() async {
    var n = 0;
    final d = await rootDir;
    await for (final e in d.list(recursive: true)) {
      if (e is File) n += await e.length();
    }
    return n;
  }

  // ── custom models ─────────────────────────────────────────────────────────────────────
  /// Copy a GGUF file into the model store (hashing it on the way) and register it.
  Future<LocalModelSpec> importFile(String sourcePath, {String? label}) async {
    final src = File(sourcePath);
    if (!await src.exists()) throw AiError('File not found');
    final head = await src.openRead(0, 4).fold<List<int>>([], (a, b) => a..addAll(b));
    if (utf8.decode(head, allowMalformed: true) != 'GGUF') throw AiError('Not a GGUF model file');
    final size = await src.length();
    final name = sourcePath.split(Platform.pathSeparator).last;
    final id = 'custom-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    final free = await _freeSpace((await rootDir).path);
    if (free != null && free < size + storageMargin) {
      throw AiError('Not enough storage to import ${formatBytes(size)} (${formatBytes(free)} free)');
    }
    final file = ModelFile(name, '', sha256: '', sizeBytes: size);
    final dest = await pathOf(id, file);
    await Directory(await dirOf(id)).create(recursive: true);
    final digest = _DigestSink();
    final hasher = sha256.startChunkedConversion(digest);
    final sink = File('$dest.part').openWrite();
    await for (final c in src.openRead()) {
      hasher.add(c);
      sink.add(c);
    }
    await sink.close();
    hasher.close();
    await File('$dest.part').rename(dest);
    final m = LocalModelSpec(
      id: id,
      kind: LocalKind.llm,
      label: (label == null || label.trim().isEmpty) ? name.replaceAll(RegExp(r'\.gguf$', caseSensitive: false), '') : label.trim(),
      licence: 'unknown (custom)',
      summary: 'Imported from a file',
      files: [ModelFile(name, '', sha256: digest.value.toString(), sizeBytes: size)],
      minRamBytes: _ramFor(size),
      custom: true,
    );
    (await customModels()).add(m);
    await _saveCustom();
    changes.add(id);
    return m;
  }

  /// Register a GGUF by URL (download it with [download]). The SHA-256 is [sha256] if given;
  /// for a huggingface.co URL it is read from the `X-Linked-Etag` header Hugging Face sends
  /// for LFS files. Without either, the download is checked only by its size.
  Future<LocalModelSpec> addUrl(String url, {String? label, String? sha256Hex}) async {
    final u = Uri.tryParse(url.trim());
    if (u == null || !(u.isScheme('https') || u.isScheme('http')) || u.host.isEmpty) throw AiError('Enter an http(s) URL');
    var name = u.pathSegments.isEmpty ? 'model.gguf' : u.pathSegments.last;
    if (!name.toLowerCase().endsWith('.gguf')) throw AiError('The URL must point to a .gguf file');
    var hash = (sha256Hex ?? '').trim().toLowerCase();
    if (hash.isNotEmpty && !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) throw AiError('SHA-256 must be 64 hex characters');
    var size = 0;
    final client = _client();
    try {
      final r = await client.head(u).timeout(const Duration(seconds: 20));
      if (r.statusCode >= 400) throw AiError('The server answered HTTP ${r.statusCode}');
      final linked = (r.headers['x-linked-etag'] ?? '').replaceAll('"', '').toLowerCase();
      if (hash.isEmpty && RegExp(r'^[0-9a-f]{64}$').hasMatch(linked)) hash = linked;
      size = int.tryParse(r.headers['x-linked-size'] ?? '') ?? int.tryParse(r.headers['content-length'] ?? '') ?? 0;
    } on AiError {
      rethrow;
    } catch (e) {
      throw AiError('Could not reach the URL: $e');
    } finally {
      client.close();
    }
    name = Uri.decodeComponent(name);
    final m = LocalModelSpec(
      id: 'custom-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}',
      kind: LocalKind.llm,
      label: (label == null || label.trim().isEmpty) ? name.replaceAll(RegExp(r'\.gguf$', caseSensitive: false), '') : label.trim(),
      licence: 'unknown (custom)',
      pageUrl: url.trim(),
      summary: hash.isEmpty ? 'From a URL (no published checksum: verified by size only)' : 'From a URL (SHA-256 verified)',
      files: [ModelFile(name, u.toString(), sha256: hash, sizeBytes: size)],
      minRamBytes: _ramFor(size),
      custom: true,
    );
    (await customModels()).add(m);
    await _saveCustom();
    changes.add(m.id);
    return m;
  }

  /// Rough RAM need of a GGUF: weights + KV cache/compute buffers + the app.
  static int _ramFor(int fileBytes) => fileBytes == 0 ? 0 : fileBytes + (1536 << 20);
}

/// A readable reason for a failed download (disk full is the common one on phones).
String describeDownloadError(Object e) {
  if (e is AiError) return e.message;
  if (e is FileSystemException) {
    final code = e.osError?.errorCode;
    final msg = '${e.osError?.message ?? ''} ${e.message}'.toLowerCase();
    if (code == 28 || msg.contains('no space')) {
      return 'Not enough storage: the phone ran out of space during the download. Free some space, '
          'then download again to resume.';
    }
    return 'Download failed: could not write the model file (${e.osError?.message ?? e.message})';
  }
  return 'Download failed: $e';
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
