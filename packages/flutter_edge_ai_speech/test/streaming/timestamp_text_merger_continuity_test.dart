// Not an upstream test: continuous speech through sliding windows must come
// out once, in order, at every overlap the recognizer uses. At an overlap of
// 0.7 or more, LiteRT-LM Omni v0.19.1's TimestampTextMerger emits the words it
// confirmed early a second time when the next window still holds them; this
// port deviates from it there (see _mergeAlignedOverlap).
import 'package:flutter_edge_ai_speech/src/streaming/detokenizer.dart';
import 'package:flutter_edge_ai_speech/src/streaming/timestamp_text_merger.dart';
import 'package:flutter_test/flutter_test.dart';

/// Feeds windows of [window] timestamp units every [step] over [words]
/// (`(text, absolute onset)`), then flushes; returns every confirmed piece
/// and the final unconfirmed tail.
(List<String> confirmed, String tail) _stream(
  List<(String, int)> words, {
  required double overlap,
  required int window,
  required int end,
}) {
  final step = (window * (1 - overlap)).round();
  final merger = TimestampTextMerger(overlapRatio: overlap);
  final confirmed = <String>[];
  var tail = '';
  for (var start = 0; start + window <= end; start += step) {
    final result = merger.add([
      for (final (w, t) in words)
        if (t >= start && t < start + window)
          DetokenizedWord(w, timestampMs: t - start),
      DetokenizedWord.endOfChunk(timestampMs: window),
    ]);
    if (result.confirmed.isNotEmpty) confirmed.add(result.confirmed);
    tail = result.unconfirmed;
  }
  final flushed = merger.flush();
  if (flushed != null) {
    if (flushed.confirmed.isNotEmpty) confirmed.add(flushed.confirmed);
    tail = flushed.unconfirmed;
  }
  return (confirmed, tail);
}

void main() {
  // A word every 7 units, offset so none sits on a window boundary.
  final words = [for (var i = 0; i < 60; i++) ('w$i', 7 * i + 3)];

  for (final overlap in [0.4, 0.5, 0.75, 0.8]) {
    test('every word once, in order, at overlap $overlap', () {
      const window = 100;
      final step = (window * (1 - overlap)).round();
      // The last window that fits ends here; later words are never heard.
      final lastEnd = ((420 - window) ~/ step) * step + window;
      final (confirmed, tail) = _stream(
        words,
        overlap: overlap,
        window: window,
        end: 420,
      );
      final out = '${confirmed.join(' ')} $tail'.trim().split(RegExp(r'\s+'));
      expect(out, [
        for (final (w, t) in words)
          if (t < lastEnd) w,
      ]);
    });
  }

  test('confirmed text is never confirmed again (overlap 0.75)', () {
    final (confirmed, _) = _stream(words, overlap: 0.75, window: 100, end: 420);
    final seen = <String>{};
    for (final piece in confirmed) {
      for (final w in piece.split(' ')) {
        expect(seen.add(w), isTrue, reason: '$w confirmed twice');
      }
    }
  });
}
