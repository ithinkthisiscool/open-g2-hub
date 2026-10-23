/// Frame format and reassembly: `AA <dir> <seq> <len> <total> <num> <SID> <flag> <payload> [CRC]`.
///
/// Ports of g2.widgets.evenhub.frame_pb, g2.transport.transport (auth_frame, payload_span,
/// parse_rx, FrameAssembler) and g2.transport.session (parse_frame, read_ack_magic).
library;

import 'dart:typed_data';

import 'crc.dart';
import 'pb.dart';

/// Frame byte 7 for app -> glasses commands on the control channel.
const int flagRequest = 0x20;

/// Frame byte 7 for 0x80 auth and keep-alive (and the file service).
const int flagPlain = 0x00;

/// Max payload bytes per packet (MTU 247 - 3 ATT - 8 header - CRC room).
const int chunkSize = 232;

/// len byte of a frame produced by [FrameAssembler] (a real packet carries at most 232 + CRC).
const int assembledLen = 0xFF;

/// Wrap protobuf [pb] in one or more frames for [sid]. The CRC16 of the whole payload is
/// appended and the result is cut into chunks of up to 232 bytes (the CRC may straddle the
/// last two packets). Write each frame in order to 0x5401.
List<Uint8List> framePb(List<int> pb, int sid, int flag, int seq, {int maxWrite = 240}) {
  final size = maxWrite - 8 < chunkSize ? maxWrite - 8 : chunkSize;
  final payload = cat([pb, crc16Bytes(pb)]);
  var total = (payload.length + size - 1) ~/ size;
  if (total < 1) total = 1;
  final frames = <Uint8List>[];
  for (var i = 0; i < total; i++) {
    final a = i * size;
    final b = (a + size) > payload.length ? payload.length : a + size;
    final chunk = payload.sublist(a, b);
    frames.add(cat([
      [0xAA, 0x21, seq & 0xFF, chunk.length & 0xFF, total & 0xFF, (i + 1) & 0xFF, sid & 0xFF, flag & 0xFF],
      chunk,
    ]));
  }
  return frames;
}

/// transport.add_crc: packet + CRC16 (LE) of everything after the 8-byte header.
Uint8List addCrc(List<int> packet) => cat([packet, crc16Bytes(packet.sublist(8))]);

/// transport.build_frames (EXPERIMENTAL in the Python library; prefer [framePb]). Same
/// chunking as framePb with a fixed 232-byte chunk, kept for parity.
List<Uint8List> buildFramesLegacy(int seq, int serviceHi, int serviceLo, List<int> payload) {
  final body = cat([payload, crc16Bytes(payload)]);
  var total = (body.length + chunkSize - 1) ~/ chunkSize;
  if (total < 1) total = 1;
  final out = <Uint8List>[];
  var offset = 0;
  for (var i = 0; i < total; i++) {
    final end = offset + chunkSize > body.length ? body.length : offset + chunkSize;
    final chunk = body.sublist(offset, end);
    offset = end;
    out.add(cat([
      [0xAA, 0x21, seq, chunk.length, total, i + 1, serviceHi, serviceLo],
      chunk,
    ]));
  }
  return out;
}

/// Module-level auth counter, like transport._seq (1..255, wraps).
int _authSeq = 0;

/// Reset the auth counter (tests only).
void resetAuthSeq([int value = 0]) => _authSeq = value;

/// The one-packet authentication frame (LIVE-CONFIRMED). Returns (magic, frame).
/// `AA 21 <magic> <len> 01 01 80 00` + {1: 4, 2: magic, 3: {1: 1, 2: 4}} + CRC16.
/// Byte-identical to transport.auth_frame(), including its raw single-byte magic.
(int, Uint8List) authFrame() {
  _authSeq = (_authSeq + 1) & 0xFF;
  final magic = _authSeq;
  return (magic, authFrameFor(magic));
}

Uint8List authFrameFor(int magic) {
  final pb = [0x08, 0x04, 0x10, magic, 0x1A, 0x04, 0x08, 0x01, 0x10, 0x04];
  final pkt = [0xAA, 0x21, magic, pb.length + 2, 0x01, 0x01, 0x80, 0x00, ...pb];
  return cat([pkt, crc16Bytes(pkt.sublist(8))]);
}

/// (start, end) of the payload in one AA frame: after the header, minus the 2 CRC bytes.
(int, int) payloadSpan(List<int> frame) {
  final ln = frame[3];
  if (ln == assembledLen) return (8, frame.length - 2);
  final end = 8 + (ln - 2 > 0 ? ln - 2 : 0);
  return (8, end);
}

Uint8List _slice(List<int> b, int a, int e) {
  final n = b.length;
  final s = a > n ? n : a;
  final t = e > n ? n : (e < s ? s : e);
  return Uint8List.fromList(b.sublist(s, t));
}

/// A parsed frame: SID (byte 6), flag (byte 7) and the protobuf payload.
class ParsedFrame {
  ParsedFrame(this.sid, this.flag, this.payload);
  final int sid;
  final int flag;
  final Uint8List payload;
}

/// session.parse_frame: null for anything that is not an AA frame (or too short). CRC unchecked.
ParsedFrame? parseFrame(List<int> frame) {
  if (frame.length < 10 || frame[0] != 0xAA) return null;
  final (a, b) = payloadSpan(frame);
  return ParsedFrame(frame[6], frame[7], _slice(frame, a, b));
}

/// transport.parse_rx: (sid, payload) for a glasses -> app frame (AA 12), else (null, empty).
(int?, Uint8List) parseRx(List<int> frame) {
  if (frame.length >= 10 && frame[0] == 0xAA && frame[1] == 0x12) {
    final (a, b) = payloadSpan(frame);
    return (frame[6], _slice(frame, a, b));
  }
  return (null, Uint8List(0));
}

/// session.read_ack_magic: field 2 of a protobuf starting with field 1 then field 2 (or
/// directly field 2, since proto3 leaves out a zero command id). Null if not that shape.
int? readAckMagic(List<int> pb) {
  try {
    if (pb.length >= 2 && pb[0] == 0x10) {
      return decodeVarintAt(pb, 1).$1;
    }
    if (pb.length < 2 || pb[0] != 0x08) return null;
    final (_, i) = decodeVarintAt(pb, 1);
    if (i >= pb.length || pb[i] != 0x10) return null;
    return decodeVarintAt(pb, i + 1).$1;
  } on RangeError {
    return null;
  }
}

/// Joins multi-packet notifications back into one synthetic frame
/// `AA <dir> <seq> FF 01 01 <sid> <flag> <payload> <crc>` (see payloadSpan).
class FrameAssembler {
  final Map<int, List<Uint8List>> _parts = {};
  int crcErrors = 0;

  /// Returns the bytes to hand on, or null while a message is incomplete.
  Uint8List? feed(List<int> input) {
    final data = Uint8List.fromList(input);
    if (data.length < 8 || data[0] != 0xAA) return data;
    final total = data[4];
    final num = data[5];
    if (total <= 1) return data;
    final key = (data[6] << 8) | data[2];
    final chunk = _slice(data, 8, 8 + data[3]);
    if (num == 1) {
      _parts[key] = [chunk];
    } else if (_parts.containsKey(key) && _parts[key]!.length == num - 1) {
      _parts[key]!.add(chunk);
    } else {
      _parts.remove(key);
      return null;
    }
    if (num < total) return null;
    final body = cat(_parts.remove(key)!);
    if (body.length < 2) {
      // Python: payload = body[:-2], crc = body[-2:]; a <2-byte body never matches.
      crcErrors += 1;
    } else {
      final payload = body.sublist(0, body.length - 2);
      final c = crc16Ccitt(payload);
      if (body[body.length - 2] != (c & 0xFF) || body[body.length - 1] != ((c >> 8) & 0xFF)) {
        crcErrors += 1;
      }
    }
    return cat([
      [0xAA, data[1], data[2], assembledLen, 1, 1, data[6], data[7]],
      body,
    ]);
  }
}
