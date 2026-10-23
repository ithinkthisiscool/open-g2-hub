/// Sending a file to the glasses over the EvenFile service, the official app's way (port of
/// g2/transport/file_service.py send_file): START → per 4096-byte block a DATA prefix + 232-byte
/// packets (retried up to 3 times on CRC error / timeout / no resources) → RESULT_CHECK.
/// Notifications are fileType 1 JSON files. UNTESTED LIVE (also in the Python library).
library;

import 'dart:async';
import 'dart:typed_data';

import '../protocol/file_service.dart' as fs;
import 'glasses_session.dart';

Future<void> _lock = Future<void>.value();

String _rspName(int? r) => r == null ? 'no reply' : (fs.rspNames[r] ?? 'rsp=$r');

/// Returns (ok, message). Only one transfer runs at a time (per app).
Future<(bool, String)> sendFile(G2Session s, int fileType, Uint8List data,
    {Duration replyTimeout = const Duration(seconds: 8), Duration noResourcesWait = const Duration(seconds: 5)}) {
  final c = Completer<(bool, String)>();
  _lock = _lock.then((_) async {
    try {
      c.complete(await _send(s, fileType, data, replyTimeout, noResourcesWait));
    } catch (e) {
      c.complete((false, '$e'));
    }
  });
  return c.future;
}

Future<(bool, String)> _send(G2Session s, int fileType, Uint8List data, Duration timeout, Duration nrWait) async {
  await s.enableFileChannel();
  final replies = StreamController<(int, int)>();
  final sub = s.fileReplies.listen(replies.add);
  final it = StreamIterator(replies.stream);
  Future<int?> waitFor(int cid) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) return null;
      bool has;
      try {
        has = await it.moveNext().timeout(left);
      } on TimeoutException {
        return null;
      }
      if (!has) return null;
      if (it.current.$1 == cid) return it.current.$2;
    }
  }

  try {
    await s.sendFileFrames([fs.buildStart(s.nextSeq(), fileType, data)]);
    var rsp = await waitFor(fs.cidStart);
    s.log('EFS START type=$fileType len=${data.length}: ${_rspName(rsp)}', rsp == 0 ? LogLevel.ok : LogLevel.warn);
    if (rsp != 0) return (false, 'START ${_rspName(rsp)}');
    for (var off = 0; off < data.length; off += fs.blockSize) {
      final block = data.sublist(off, off + fs.blockSize > data.length ? data.length : off + fs.blockSize);
      var done = false;
      for (var attempt = 0; attempt < 4; attempt++) {
        final magic = s.nextSeq();
        await s.sendFileFrames([fs.buildDataPrefix(magic)]);
        await s.sendFileFrames(fs.buildDataPackets(magic, block));
        rsp = await waitFor(fs.cidData);
        s.log('EFS DATA @$off try ${attempt + 1}: ${_rspName(rsp)}', rsp == 0 ? LogLevel.ok : LogLevel.warn);
        if (rsp == 0) {
          done = true;
          break;
        }
        if (rsp != null && !fs.rspRetry.contains(rsp)) return (false, 'DATA ${_rspName(rsp)}');
        if (rsp == 5) await Future<void>.delayed(nrWait);
      }
      if (!done) return (false, 'DATA retries exhausted');
    }
    await s.sendFileFrames([fs.buildResultCheck(s.nextSeq())]);
    rsp = await waitFor(fs.cidResultCheck);
    s.log('EFS RESULT_CHECK: ${_rspName(rsp)}', rsp == 0 ? LogLevel.ok : LogLevel.warn);
    return (rsp == 0, 'RESULT_CHECK ${_rspName(rsp)}');
  } finally {
    // Not awaited: a cancelled subscription's future may complete in the root zone.
    unawaited(sub.cancel());
    unawaited(it.cancel());
    unawaited(replies.close());
  }
}
