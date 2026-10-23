/// Minimal protobuf wire encoding/decoding, byte-identical to the Python library's
/// `g2.widgets.evenhub` helpers (encode_varint, encode_*_field, _iter_fields, read_*_field).
///
/// There is no generated code: every G2 message is built field by field, exactly like the
/// Python builders, so the bytes on the wire match (field order, explicit zeros, wire types).
library;

import 'dart:convert';
import 'dart:typed_data';

/// Thrown where the Python library raises `ValueError` (bad input, firmware limit exceeded).
class G2ValueError implements Exception {
  G2ValueError(this.message);
  final String message;
  @override
  String toString() => 'G2ValueError: $message';
}

/// Growable byte buffer used by every builder (thin wrapper around [BytesBuilder]).
class Pb {
  final BytesBuilder _b = BytesBuilder(copy: false);

  Pb add(List<int> bytes) {
    _b.add(bytes);
    return this;
  }

  Pb varint(int field, int value) => add(encodeVarintField(field, value));
  Pb string(int field, String value) => add(encodeStringField(field, value));
  Pb bytes(int field, List<int> value) => add(encodeBytesField(field, value));
  Pb message(int field, List<int> inner) => add(encodeMessageField(field, inner));
  Pb float32(int field, double value) => add(encodeFloatField(field, value));
  Pb float64(int field, double value) => add(encodeDoubleField(field, value));

  int get length => _b.length;
  Uint8List toBytes() => _b.toBytes();
}

/// Protobuf varint. Negative ints are written as their unsigned 64-bit two's complement
/// (10 bytes), which is what Python's `_signed_varint` does for int32 fields.
Uint8List encodeVarint(int value) {
  final out = <int>[];
  var v = value;
  // Treat as unsigned 64-bit: >>> keeps it terminating for negatives.
  while (v < 0 || v >= 0x80) {
    out.add((v & 0x7F) | 0x80);
    v = v >>> 7;
  }
  out.add(v & 0x7F);
  return Uint8List.fromList(out);
}

Uint8List encodeKey(int field, int wireType) => encodeVarint((field << 3) | wireType);

Uint8List _cat(List<List<int>> parts) {
  final b = BytesBuilder(copy: false);
  for (final p in parts) {
    b.add(p);
  }
  return b.toBytes();
}

Uint8List encodeVarintField(int field, int value) =>
    _cat([encodeKey(field, 0), encodeVarint(value)]);

Uint8List encodeStringField(int field, String value) {
  final b = utf8.encode(value);
  return _cat([encodeKey(field, 2), encodeVarint(b.length), b]);
}

Uint8List encodeBytesField(int field, List<int> value) =>
    _cat([encodeKey(field, 2), encodeVarint(value.length), value]);

Uint8List encodeMessageField(int field, List<int> inner) =>
    _cat([encodeKey(field, 2), encodeVarint(inner.length), inner]);

/// protobuf float: wire type 5, 4 bytes little-endian (Python struct.pack('<f')).
Uint8List encodeFloatField(int field, double value) {
  final d = ByteData(4)..setFloat32(0, value, Endian.little);
  return _cat([encodeKey(field, 5), d.buffer.asUint8List()]);
}

/// protobuf double: wire type 1, 8 bytes little-endian.
Uint8List encodeDoubleField(int field, double value) {
  final d = ByteData(8)..setFloat64(0, value, Endian.little);
  return _cat([encodeKey(field, 1), d.buffer.asUint8List()]);
}

/// Packed repeated varints (dashboard widgetDisplayOrder etc.).
Uint8List encodePackedVarintField(int field, List<int> values) =>
    encodeMessageField(field, _cat(values.map(encodeVarint).toList()));

/// Concatenate byte lists.
Uint8List cat(List<List<int>> parts) => _cat(parts);

/// (value, nextIndex). Throws [RangeError] on a truncated varint, like Python's IndexError.
(int, int) decodeVarintAt(List<int> data, int i) {
  var result = 0;
  var shift = 0;
  while (true) {
    final b = data[i];
    if (shift < 64) result |= (b & 0x7F) << shift;
    i += 1;
    if (b & 0x80 == 0) return (result, i);
    shift += 7;
  }
}

/// One top-level protobuf field. [value] is an int for wire type 0, else the raw bytes.
class PbField {
  PbField(this.number, this.wire, this.value);
  final int number;
  final int wire;
  final Object value;
  int get asInt => value as int;
  Uint8List get asBytes => value as Uint8List;
}

/// Port of `_iter_fields`: stops at an unknown wire type; slices past the end are clipped
/// exactly like Python slicing.
Iterable<PbField> iterFields(List<int> pb) sync* {
  var i = 0;
  final n = pb.length;
  Uint8List slice(int a, int b) {
    final s = a > n ? n : a;
    final e = b > n ? n : b;
    return Uint8List.fromList(pb.sublist(s, e < s ? s : e));
  }

  while (i < n) {
    final (key, i1) = decodeVarintAt(pb, i);
    i = i1;
    final field = key >>> 3;
    final wire = key & 7;
    if (wire == 0) {
      final (v, i2) = decodeVarintAt(pb, i);
      i = i2;
      yield PbField(field, wire, v);
    } else if (wire == 1) {
      yield PbField(field, wire, slice(i, i + 8));
      i += 8;
    } else if (wire == 2) {
      final (length, i2) = decodeVarintAt(pb, i);
      i = i2;
      yield PbField(field, wire, slice(i, i + length));
      i += length;
    } else if (wire == 5) {
      yield PbField(field, wire, slice(i, i + 4));
      i += 4;
    } else {
      return;
    }
  }
}

int readVarintField(List<int> pb, int field, [int def = -1]) {
  for (final f in iterFields(pb)) {
    if (f.number == field && f.wire == 0) return f.asInt;
  }
  return def;
}

String readStringField(List<int> pb, int field, [String def = '']) {
  for (final f in iterFields(pb)) {
    if (f.number == field && f.wire == 2) return utf8.decode(f.asBytes, allowMalformed: true);
  }
  return def;
}

Uint8List? readBytesField(List<int> pb, int field) {
  for (final f in iterFields(pb)) {
    if (f.number == field && f.wire == 2) return f.asBytes;
  }
  return null;
}

double readFloatField(List<int> pb, int field, [double def = 0.0]) {
  for (final f in iterFields(pb)) {
    if (f.number == field && f.wire == 5) {
      final b = f.asBytes;
      if (b.length < 4) throw RangeError('truncated float');
      return ByteData.sublistView(b).getFloat32(0, Endian.little);
    }
  }
  return def;
}

/// Undo a signed int32 written as a 64-bit two's complement varint. Dart ints are already
/// 64-bit two's complement, so the decoded value is correct as-is.
int decodeSigned(int value) => value;

/// Lower-case hex, no separator (Python bytes.hex()).
String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List unhex(String s) {
  final t = s.replaceAll(' ', '');
  final out = Uint8List(t.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(t.substring(2 * i, 2 * i + 2), radix: 16);
  }
  return out;
}
