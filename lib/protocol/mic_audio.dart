/// Glasses microphone packets (notify 0x6402 on service 0x6450, raw, no AA frame, no CRC).
///
/// Layout (g2/transport/session.py enable_mic, Faceclaw Lc3PacketFramer, and the 386 real
/// packets in esp32_ai/docs/captures/scratch-0924-0928/real_btsnoop_hci2.log):
///
///     bytes   0..199  five 40-byte LC3 frames, 10 ms each, 16 kHz mono (32 kbps)
///     bytes 200..201  int16 LE signal-strength ratio
///     bytes 202..203  int16 LE direction of arrival (degrees)
///     byte  204       packet counter (wraps at 256)
///
/// The mic streams after Even AI CTRL ENTER, or after EvenHub audio control on (SID 0xE0 cmd
/// 15, evenhub.buildAudioControl). Subscribe on both lenses; the left one is usually cleaner.
library;

import 'dart:typed_data';

const int sampleRate = 16000;
const int frameBytes = 40;
const int framesPerPacket = 5;
const int audioBytes = frameBytes * framesPerPacket; // 200
const int packetBytes = audioBytes + 5; // 205
const int samplesPerFrame = 160; // 10 ms at 16 kHz
const int samplesPerPacket = samplesPerFrame * framesPerPacket; // 800 = 50 ms

class MicPacket {
  MicPacket(this.frames, {this.signalRatio, this.direction, this.counter});
  final List<Uint8List> frames;
  final int? signalRatio;
  final int? direction;
  final int? counter;
}

/// Split one notification into its LC3 frames + trailer; null when it is too short to hold
/// the 200 audio bytes (the hub's Lc3Stream.decode returns b'' for those).
MicPacket? parseMicPacket(List<int> data) {
  if (data.length < audioBytes) return null;
  final b = data is Uint8List ? data : Uint8List.fromList(data);
  final frames = [for (var i = 0; i < framesPerPacket; i++) Uint8List.sublistView(b, i * frameBytes, (i + 1) * frameBytes)];
  if (b.length < packetBytes) return MicPacket(frames);
  final bd = ByteData.sublistView(b);
  return MicPacket(frames,
      signalRatio: bd.getInt16(audioBytes, Endian.little),
      direction: bd.getInt16(audioBytes + 2, Endian.little),
      counter: b[audioBytes + 4]);
}
