/// Even AI (SID 0x07): the "Hey Even" voice assistant screen. Port of g2/apps/even_ai.py
/// (LIVE-CONFIRMED in the Python hub), byte-exact (test/ai/even_ai_vectors_test.dart).
///
///     glasses → CTRL WAKE_UP        user said "Hey Even" / opened Even AI
///     app     → CTRL ENTER          accept (the glasses give up after a few seconds without it)
///     app     → HEARTBEAT every 2 s keeps the session open
///     glasses → mic audio           LC3 on notify 0x6402 (see mic_audio.dart)
///     (app detects silence)         the glasses never send VAD_END in practice
///     app     → ASK {text}          the recognised question
///     app     → ANALYSE             "thinking" screen
///     app     → REPLY {text, end}   ≤512 UTF-8 bytes per packet, ~150 ms apart
///     glasses → EVENT STREAM_COMPLETE
///     either  → CTRL EXIT
library;

import 'dart:convert';
import 'dart:typed_data';

import 'pb.dart';

const int sid = 0x07;

const int cmdCtrl = 1, cmdVadInfo = 2, cmdAsk = 3, cmdAnalyse = 4, cmdReply = 5, cmdSkill = 6;
const int cmdPrompt = 7, cmdEvent = 8, cmdHeartbeat = 9, cmdConfig = 10, cmdCommRsp = 0xA1;

const Map<int, String> cmdNames = {
  cmdCtrl: 'CTRL', cmdVadInfo: 'VAD_INFO', cmdAsk: 'ASK', cmdAnalyse: 'ANALYSE', cmdReply: 'REPLY', //
  cmdSkill: 'SKILL', cmdPrompt: 'PROMPT', cmdEvent: 'EVENT', cmdHeartbeat: 'HEARTBEAT', cmdConfig: 'CONFIG',
  cmdCommRsp: 'COMM_RSP',
};

/// Protobuf field carrying the sub-message of each command.
const Map<int, int> fieldForCmd = {
  cmdCtrl: 3, cmdVadInfo: 4, cmdAsk: 5, cmdAnalyse: 6, cmdReply: 7, cmdSkill: 8, cmdPrompt: 9, //
  cmdEvent: 10, cmdHeartbeat: 11, cmdCommRsp: 12, cmdConfig: 13,
};

const int ctrlWakeUp = 1, ctrlEnter = 2, ctrlExit = 3;
const Map<int, String> ctrlNames = {ctrlWakeUp: 'WAKE_UP', ctrlEnter: 'ENTER', ctrlExit: 'EXIT'};

const int vadStart = 1, vadEnd = 2, vadTimeout = 3;
const Map<int, String> vadNames = {vadStart: 'VAD_START', vadEnd: 'VAD_END', vadTimeout: 'VAD_TIMEOUT'};

const int eventScroll = 1, eventStreamComplete = 2;
const Map<int, String> eventNames = {eventScroll: 'SCROLL', eventStreamComplete: 'STREAM_COMPLETE'};

const Map<int, String> promptNames = {
  1: 'NETWORK_ERR', 2: 'BLE_DISCONNECT', 3: 'SERVER_ERR', 4: 'TROUBLE_UNDERSTAND', 5: 'COMMAND_UNSUPPORT', //
  6: 'AUDIO_ERROR', 7: 'ASR_SERVER_ERR', 8: 'AI_SERVER_ERR', 9: 'COMMAND_EXE_FAIL',
};

const int replyMaxBytes = 512;
const Duration replyPace = Duration(milliseconds: 150);
const Duration heartbeatInterval = Duration(seconds: 2);
const int defaultStreamSpeed = 80;

/// EvenAIDataPackage {1 cmd, 2 magic, (the field for cmd) inner}.
Uint8List buildPackage(int cmd, int magic, List<int> inner) =>
    cat([encodeVarintField(1, cmd), encodeVarintField(2, magic), encodeMessageField(fieldForCmd[cmd]!, inner)]);

Uint8List buildCtrl(int magic, int status) => buildPackage(cmdCtrl, magic, encodeVarintField(1, status));

Uint8List buildHeartbeat(int magic, int count) => buildPackage(cmdHeartbeat, magic, encodeVarintField(1, count));

Uint8List buildConfig(int magic, {int voiceSwitch = 0, int streamSpeed = defaultStreamSpeed}) =>
    buildPackage(cmdConfig, magic, cat([encodeVarintField(1, voiceSwitch), encodeVarintField(2, streamSpeed)]));

Uint8List _textInfo(List<int> textBytes, {bool finalChunk = false}) {
  final inner = encodeMessageField(4, textBytes);
  return finalChunk ? cat([inner, encodeVarintField(6, 1)]) : inner;
}

Uint8List buildAsk(int magic, String text) => buildPackage(cmdAsk, magic, _textInfo(utf8.encode(text)));

Uint8List buildAnalyse(int magic) => buildPackage(cmdAnalyse, magic, Uint8List(0));

/// One REPLY chunk (bytes, at most [replyMaxBytes]); [finalChunk] marks the last.
Uint8List buildReply(int magic, List<int> chunk, bool finalChunk) =>
    buildPackage(cmdReply, magic, _textInfo(chunk, finalChunk: finalChunk));

/// Split [text] into ≤[limit]-byte UTF-8 chunks without cutting a character (Python iterates
/// code points, so does this). Always at least one chunk.
List<Uint8List> replyChunks(String text, [int limit = replyMaxBytes]) {
  limit = limit > replyMaxBytes ? replyMaxBytes : limit;
  if (limit < 1) limit = 1;
  final chunks = <Uint8List>[];
  final cur = BytesBuilder(copy: false);
  for (final rune in text.runes) {
    final b = utf8.encode(String.fromCharCode(rune));
    if (cur.length + b.length > limit && cur.length > 0) {
      chunks.add(cur.takeBytes());
    }
    cur.add(b);
  }
  chunks.add(cur.takeBytes());
  return chunks;
}

/// Decode any Even AI message from the glasses: {cmd, name, magic, value, error, label}.
Map<String, Object?> decode(List<int> pb) {
  final cmd = readVarintField(pb, 1, -1);
  final magic = readVarintField(pb, 2, -1);
  final name = cmdNames[cmd] ?? 'cmd=$cmd';
  int? value, error;
  final field = fieldForCmd[cmd];
  final sub = field != null ? readBytesField(pb, field) : null;
  var label = name;
  if (sub != null) {
    if (cmd == cmdCommRsp) {
      error = readVarintField(sub, 1, 0);
    } else {
      value = readVarintField(sub, 1, 0);
      error = readVarintField(sub, 2, 0);
    }
    final names = switch (cmd) {
      cmdCtrl => ctrlNames,
      cmdVadInfo => vadNames,
      cmdEvent => eventNames,
      cmdPrompt => promptNames,
      _ => null,
    };
    if (names != null) label += ' ${names[value] ?? value}';
    if (error != 0) label += ' errorCode=$error';
  }
  return {'cmd': cmd, 'name': name, 'magic': magic, 'value': value, 'error': error, 'label': label};
}
