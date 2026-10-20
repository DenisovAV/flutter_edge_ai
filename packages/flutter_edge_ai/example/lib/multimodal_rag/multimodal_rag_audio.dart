// Voice-memo audio helpers. Pure Dart; unit-tested in
// test/knowledge_audio_test.dart.

import 'dart:math' as math;
import 'dart:typed_data';

import '../utils/audio_converter.dart';

/// 16 kHz mono PCM16, the format speech-to-text takes: two bytes a sample.
const kPcmBytesPerSecond = AudioConverter.targetSampleRate * 2;

/// The samples of a WAV file as 16 kHz mono PCM16 (no header), resampled and
/// mixed down when the file is in another format.
Uint8List pcm16kMonoFromWav(Uint8List wav) {
  final parsed = AudioConverter.parseWav(wav);
  return AudioConverter.toPCM16kHzMono(
    parsed.pcmData,
    sourceSampleRate: parsed.sampleRate,
    sourceChannels: parsed.channels,
  );
}

/// How long 16 kHz mono PCM16 [pcm] plays.
Duration pcmDuration(Uint8List pcm) => Duration(
  microseconds:
      pcm.length * Duration.microsecondsPerSecond ~/ kPcmBytesPerSecond,
);

/// Splits 16 kHz mono PCM16 [pcm] into pieces no longer than [window] — the
/// speech-to-text model's window (Moonshine and Parakeet hear five seconds,
/// Whisper thirty, and cut what is longer). Each cut is made at the quietest
/// 100 ms in the last [search] of a window, so a word is rarely split.
List<Uint8List> splitForSpeechWindow(
  Uint8List pcm, {
  required Duration window,
  Duration search = const Duration(milliseconds: 1500),
}) {
  final windowBytes = _bytes(window);
  if (windowBytes <= 0) throw ArgumentError.value(window, 'window');
  final frameBytes = _bytes(const Duration(milliseconds: 100));
  final searchBytes = math.min(_bytes(search), windowBytes ~/ 2);
  final pieces = <Uint8List>[];
  var start = 0;
  while (pcm.length - start > windowBytes) {
    final end = start + windowBytes;
    var cut = end;
    var quietest = double.infinity;
    for (
      var frame = end - searchBytes;
      frame + frameBytes <= end;
      frame += frameBytes ~/ 2
    ) {
      final energy = _energy(pcm, frame, frameBytes);
      if (energy < quietest) {
        quietest = energy;
        cut = frame + frameBytes ~/ 2;
      }
    }
    cut -= cut.isOdd ? 1 : 0; // on a sample boundary
    pieces.add(Uint8List.sublistView(pcm, start, cut));
    start = cut;
  }
  if (start < pcm.length) pieces.add(Uint8List.sublistView(pcm, start));
  return pieces;
}

int _bytes(Duration d) =>
    (d.inMicroseconds * kPcmBytesPerSecond ~/ Duration.microsecondsPerSecond) &
    ~1;

double _energy(Uint8List pcm, int offset, int length) {
  final view = ByteData.sublistView(pcm, offset, offset + length);
  var sum = 0.0;
  for (var i = 0; i + 1 < length; i += 2) {
    final sample = view.getInt16(i, Endian.little);
    sum += sample * sample;
  }
  return sum;
}
