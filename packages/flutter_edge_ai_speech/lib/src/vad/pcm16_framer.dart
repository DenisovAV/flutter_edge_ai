// Cuts a stream of 16-bit little-endian PCM chunks of any size into whole
// frames of float samples in [-1, 1]. Pure Dart: chunks from a microphone
// rarely line up with a frame, or even with a sample (an odd byte count), so
// the remainder is carried to the next chunk.
library;

import 'dart:typed_data';

/// Turns PCM16 LE chunks into whole frames of [frameSamples] float samples.
final class Pcm16Framer {
  Pcm16Framer(this.frameSamples) : _pending = Float32List(frameSamples);

  final int frameSamples;
  final Float32List _pending;
  int _pendingCount = 0;
  int? _oddByte;
  int _totalSamples = 0;

  /// Samples received so far, whole samples only.
  int get totalSamples => _totalSamples;

  /// Samples waiting for a whole frame: what [flushPadded] would return
  /// before its zero padding.
  int get pendingSamples => _pendingCount;

  /// Adds [chunk]; returns the whole frames it completes, back to back
  /// (possibly none).
  Float32List add(Uint8List chunk) {
    var bytes = chunk;
    final odd = _oddByte;
    if (odd != null) {
      bytes = Uint8List(chunk.length + 1)
        ..[0] = odd
        ..setRange(1, chunk.length + 1, chunk);
      _oddByte = null;
    }
    final sampleCount = bytes.length ~/ 2;
    if (bytes.length.isOdd) _oddByte = bytes[bytes.length - 1];
    _totalSamples += sampleCount;

    final frames = (_pendingCount + sampleCount) ~/ frameSamples;
    final out = Float32List(frames * frameSamples);
    var written = 0;
    if (out.isNotEmpty) {
      // The carried samples open the first frame.
      out.setRange(0, _pendingCount, _pending);
      written = _pendingCount;
      _pendingCount = 0;
    }
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < sampleCount; i++) {
      final sample = data.getInt16(i * 2, Endian.little) / 32768.0;
      if (written < out.length) {
        out[written++] = sample;
      } else {
        _pending[_pendingCount++] = sample;
      }
    }
    return out;
  }

  /// The samples left over, zero-padded to one whole frame; empty when none
  /// are left. A trailing odd byte (half a sample) is dropped.
  Float32List flushPadded() {
    if (_pendingCount == 0) return Float32List(0);
    final out = Float32List(frameSamples)..setRange(0, _pendingCount, _pending);
    _pendingCount = 0;
    _oddByte = null;
    return out;
  }
}
