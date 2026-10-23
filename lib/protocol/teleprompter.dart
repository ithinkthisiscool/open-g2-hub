/// Teleprompter (SID 0x06). Port of g2/apps/teleprompter.py (DECODED from the official app;
/// untested live). paginate() reproduces Python's textwrap-based layout byte for byte.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'limits.dart' as lim;
import 'pb.dart';
import 'pytext.dart';

const int sid = 0x06;
const int cmdControl = 1, cmdFileList = 2, cmdPageData = 3, cmdPageAiSync = 4, cmdStatusNotify = 161;
const int cmdFileListRequest = 162, cmdFileSelect = 163, cmdPageDataRequest = 164, cmdPageScrollSync = 165;
const int cmdCommResp = 166, cmdPageLoadDone = 167, cmdModeSwitchReq = 168, cmdModeSwitchRsp = 169;
const int cmdEndSessionRequest = 170, cmdHeartbeat = 255;
const Map<int, String> cmdNames = {
  1: 'CONTROL', 2: 'FILE_LIST', 3: 'PAGE_DATA', 4: 'PAGE_AI_SYNC', 161: 'STATUS_NOTIFY', 162: 'FILE_LIST_REQUEST',
  163: 'FILE_SELECT', 164: 'PAGE_DATA_REQUEST', 165: 'PAGE_SCROLL_SYNC', 166: 'COMM_RESP', 167: 'PAGE_LOAD_DONE',
  168: 'MODE_SWITCH_REQ', 169: 'MODE_SWITCH_RSP', 170: 'END_SESSION_REQUEST', 255: 'HEARTBEAT', //
};
const Map<int, int> fieldForCmd = {
  1: 3, 2: 4, 3: 5, 4: 6, 161: 7, 162: 8, 163: 9, 164: 10, 165: 11, 166: 12, 255: 13, 167: 14, 168: 15, 169: 16, 170: 17, //
};

const int ctrlNone = 0, ctrlStart = 1, ctrlPause = 2, ctrlResume = 3, ctrlClose = 4;
const Map<int, String> ctrlNames = {0: 'NONE', 1: 'START', 2: 'PAUSE', 3: 'RESUME', 4: 'CLOSE'};
const int modeAi = 0, modeManual = 1, modeAuto = 2;
const Map<int, String> modeNames = {0: 'AI', 1: 'MANUAL', 2: 'AUTO'};
const Map<int, String> errorNames = {0: 'SUCCESS', 1: 'FAIL', 2: 'CLOSED', 3: 'REPEATED_MESSAGE', 4: 'PD_DECODE_FAIL', 5: 'FALLBACK_FAIL'};

const int displayWidth = 567;
const int displayLines = 9;
const int linesPerPage = 10;
const int charsPerLine = 28;
const int filenameMaxChars = 30;
const Duration heartbeatInterval = Duration(seconds: 6);
const int heartbeatMaxLost = 10;

Uint8List buildPackage(int cmd, int magic, List<int> inner) =>
    cat([encodeVarintField(1, cmd), encodeVarintField(2, magic), encodeMessageField(fieldForCmd[cmd]!, inner)]);

Uint8List _nz(int field, int value) => value != 0 ? encodeVarintField(field, value) : Uint8List(0);

/// Word-wrap into lines of <= charsPerLine characters, grouped into pages of <= linesPerPage.
List<List<String>> paginate(String script, {int charsPerLine = charsPerLine, int linesPerPage = linesPerPage}) {
  final lines = <String>[];
  for (var para in script.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n')) {
    para = pyStrip(pyExpandTabs(para, 4));
    final w = textwrapWrap(para, charsPerLine);
    lines.addAll(w.isEmpty ? [''] : w);
  }
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  while (lines.isNotEmpty && lines.first.isEmpty) {
    lines.removeAt(0);
  }
  return _packPages(lines, linesPerPage);
}

List<String> _splitLine(String line, int maxBytes) {
  final pieces = <String>[];
  var rest = line;
  while (utf8.encode(rest).length > maxBytes) {
    var head = lim.utf8Fit(rest, maxBytes);
    if (head.isEmpty) head = String.fromCharCode(rest.runes.first);
    pieces.add(head);
    rest = String.fromCharCodes(rest.runes.skip(head.runes.length));
  }
  pieces.add(rest);
  return pieces;
}

List<List<String>> _packPages(List<String> lines, int perPage) {
  const budget = lim.teleprompterPageMaxBytes - 2;
  final pages = <List<String>>[];
  var cur = <String>[];
  var used = 0;
  for (final line in lines) {
    for (final piece in _splitLine(line, budget)) {
      var need = utf8.encode(piece).length + (cur.isNotEmpty ? 1 : 0);
      if (cur.isNotEmpty && (cur.length >= perPage || used + need > budget)) {
        pages.add(cur);
        cur = <String>[];
        used = 0;
        need = utf8.encode(piece).length;
      }
      cur.add(piece);
      used += need;
    }
  }
  if (cur.isNotEmpty) pages.add(cur);
  return pages;
}

(int, int) totals(List<List<String>> pages) => (pages.length, pages.fold(0, (a, p) => a + p.length));

Uint8List buildSettings(int totalPages, int totalLines,
    {int mode = modeManual,
    int startPage = 0,
    int startLine = 0,
    int displayWidth = displayWidth,
    int scrollIntervalMs = 0,
    int countdownSeconds = 0,
    int displayLines = displayLines}) =>
    cat([
      _nz(1, mode), _nz(2, startPage), _nz(3, startLine), _nz(4, totalPages), _nz(5, totalLines), //
      _nz(6, displayWidth), _nz(7, scrollIntervalMs), _nz(8, countdownSeconds), _nz(9, displayLines),
    ]);

/// CONTROL START {1 START, 2 settings}.
Uint8List buildStart(int magic, int totalPages, int totalLines,
    {int mode = modeManual, int startPage = 0, int startLine = 0, int scrollIntervalMs = 0, int countdownSeconds = 0}) {
  final inner = cat([
    encodeVarintField(1, ctrlStart),
    encodeMessageField(
        2,
        buildSettings(totalPages, totalLines,
            mode: mode,
            startPage: startPage,
            startLine: startLine,
            scrollIntervalMs: scrollIntervalMs,
            countdownSeconds: countdownSeconds)),
  ]);
  return buildPackage(cmdControl, magic, inner);
}

Uint8List buildCtrl(int magic, int ctrl) => buildPackage(cmdControl, magic, encodeVarintField(1, ctrl));
Uint8List buildPause(int magic) => buildCtrl(magic, ctrlPause);
Uint8List buildResume(int magic) => buildCtrl(magic, ctrlResume);
Uint8List buildClose(int magic) => buildCtrl(magic, ctrlClose);

Uint8List pageText(List<String> lines) => Uint8List.fromList(utf8.encode('${lines.join('\n')} \n'));

/// PAGE_DATA {1 pageId, 2 lineCount, 3 text}; throws above the 1024-byte firmware cap.
Uint8List buildPage(int magic, int pageId, List<String> lines) {
  final text = pageText(lines);
  if (text.length > lim.teleprompterPageMaxBytes) {
    throw G2ValueError('teleprompter page text is ${text.length} bytes; firmware limit is ${lim.teleprompterPageMaxBytes}');
  }
  return buildPackage(cmdPageData, magic, cat([_nz(1, pageId), _nz(2, lines.length), encodeBytesField(3, text)]));
}

Uint8List buildHeartbeat(int magic, {int pageId = 0, int lineId = 0}) =>
    buildPackage(cmdHeartbeat, magic, cat([_nz(1, pageId), _nz(2, lineId)]));

Uint8List buildScrollSync(int magic, int pageId, int lineId) =>
    buildPackage(cmdPageScrollSync, magic, cat([_nz(1, pageId), _nz(2, lineId)]));

Uint8List buildAiSync(int magic, int pageId, int lineId, int charId) =>
    buildPackage(cmdPageAiSync, magic, cat([_nz(1, pageId), _nz(2, lineId), _nz(3, charId)]));

/// FILE_LIST for a menu launch. files: (fileId, name); names cut to 30 characters.
Uint8List buildFileList(int magic, List<(Object, String)> files, {int? menuMode}) {
  final p = Pb();
  for (final (fileId, name) in files) {
    final fid = fileId is List<int> ? fileId : utf8.encode(fileId.toString());
    p.message(1, cat([encodeBytesField(1, fid), encodeStringField(2, pyHead(name, filenameMaxChars))]));
  }
  if (menuMode != null) p.message(2, _nz(1, menuMode));
  return buildPackage(cmdFileList, magic, p.toBytes());
}

Uint8List buildModeSwitchResponse(int magic, [int error = 0]) => buildPackage(cmdModeSwitchRsp, magic, _nz(1, error));

/// Decode a teleprompter message from the glasses. `file_id` is raw bytes (Uint8List).
Map<String, Object?> decode(List<int> pb) {
  final cmd = readVarintField(pb, 1, -1);
  final magic = readVarintField(pb, 2, -1);
  final name = cmdNames[cmd] ?? 'cmd=$cmd';
  final field = fieldForCmd[cmd];
  final sub = field != null ? readBytesField(pb, field) : null;
  final out = <String, Object?>{
    'cmd': cmd, 'name': name, 'magic': magic, 'page': null, 'line': null, 'start_page': null, //
    'end_page': null, 'value': null, 'file_id': null, 'error': null,
  };
  var label = name;
  if (sub != null) {
    int v(int n) => readVarintField(sub, n, 0);
    if (cmd == cmdPageDataRequest) {
      out['page'] = v(1);
      label += ' page=${out['page']}';
    } else if (cmd == cmdPageScrollSync) {
      out['page'] = v(1);
      out['line'] = v(2);
      label += ' page=${out['page']} line=${out['line']}';
    } else if (cmd == cmdHeartbeat) {
      out['page'] = v(3);
      out['line'] = v(4);
      label += ' page=${out['page']} line=${out['line']}';
    } else if (cmd == cmdPageLoadDone) {
      out['start_page'] = v(1);
      out['end_page'] = v(2);
      label += ' pages=${out['start_page']}..${out['end_page']}';
    } else if (cmd == cmdStatusNotify) {
      out['value'] = v(1);
      out['error'] = v(2);
      label += ' ${ctrlNames[out['value']] ?? out['value']}';
    } else if (cmd == cmdControl) {
      out['value'] = v(1);
      out['error'] = v(3);
      label += ' ${ctrlNames[out['value']] ?? out['value']}';
    } else if (cmd == cmdFileSelect) {
      final fid = readBytesField(sub, 1) ?? Uint8List(0);
      out['file_id'] = fid;
      label += ' file=${utf8.decode(fid, allowMalformed: true)}';
    } else if (cmd == cmdModeSwitchReq) {
      out['value'] = v(1);
      label += ' ${modeNames[out['value']] ?? out['value']}';
    } else if (cmd == cmdCommResp || cmd == cmdModeSwitchRsp) {
      out['error'] = v(1);
      if (cmd == cmdCommResp) label += ' ${errorNames[out['error']] ?? out['error']}';
    }
    final e = out['error'];
    if (e is int && e != 0 && cmd != cmdCommResp) label += ' errCode=${errorNames[e] ?? e}';
  }
  out['label'] = label;
  return out;
}

/// True when a decode() result means the glasses ended the session.
bool isClose(Map<String, Object?> msg) =>
    msg['cmd'] == cmdEndSessionRequest || (msg['cmd'] == cmdStatusNotify && msg['value'] == ctrlClose);

/// Group already-wrapped lines into pages (Python _pack_pages; exposed for tests/UI).
List<List<String>> paginateLines(List<String> lines, [int perPage = linesPerPage]) => _packPages(lines, perPage);
