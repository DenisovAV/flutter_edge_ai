// Pure-Dart helper: splice per-clause PCM segments (produced by the TTS
// worker's clause chunker in `tts_worker.dart`) into one continuous 16-bit
// PCM buffer, inserting a fixed silence gap between clauses so consecutive
// segments don't click together. No FFI, unit-testable in isolation.
library;

import 'dart:typed_data';

/// Concatenate 16-bit PCM segments [segs], inserting [silenceSamples] of
/// silence (`silenceSamples * 2` zero bytes) BETWEEN segments — not before
/// the first or after the last. A single-segment input is returned
/// untouched (no gap to insert).
Uint8List concatPcmWithSilence(
  List<Uint8List> segs, {
  required int silenceSamples,
}) {
  final gap = silenceSamples * 2;
  var total = 0;
  for (var i = 0; i < segs.length; i++) {
    total += segs[i].length + (i > 0 ? gap : 0);
  }
  final out = Uint8List(total);
  var off = 0;
  for (var i = 0; i < segs.length; i++) {
    if (i > 0) off += gap; // zero-filled by Uint8List's default allocation.
    out.setRange(off, off + segs[i].length, segs[i]);
    off += segs[i].length;
  }
  return out;
}
