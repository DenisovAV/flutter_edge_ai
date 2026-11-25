// The merger at a window start that cuts a word: Parakeet hears the word's
// tail and emits it 5-7 encoder frames into the new window, past Omni's
// substitution tolerance. The tail must not be inserted into the transcript
// ("satisfaction faction"), and the words around it must stay. A Parakeet-like
// clock: 63-frame windows, the real step 15.625 frames at 0.75.
import 'dart:math' as math;

import 'package:flutter_edge_ai_speech/src/streaming/detokenizer.dart';
import 'package:flutter_edge_ai_speech/src/streaming/text_merger.dart';
import 'package:flutter_edge_ai_speech/src/streaming/timestamp_text_merger.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _Word = ({String text, double onset, double end});

List<String> _run(List<_Word> words, double overlap, int fragmentDelay) {
  const window = 63;
  final step = 80000 * (1 - overlap) / 1280;
  final total = words.last.end + 70;
  final merger = TimestampTextMerger(overlapRatio: overlap);
  final out = <String>[];
  void take(MergeResult? r) {
    if (r != null && r.confirmed.isNotEmpty) out.addAll(r.confirmed.split(' '));
  }

  for (var k = 0; k * step + 62.5 <= total; k++) {
    final start = k * step;
    final chunk = <DetokenizedWord>[];
    for (final w in words) {
      if (w.onset >= start && w.onset < start + 62.5) {
        chunk.add(
          DetokenizedWord(w.text, timestampMs: (w.onset - start).round()),
        );
      } else if (fragmentDelay >= 0 &&
          w.onset < start &&
          w.end > start + 1 &&
          w.text.length > 4) {
        // The window starts inside this word: the model hears its tail.
        chunk.add(
          DetokenizedWord(
            w.text.substring(w.text.length ~/ 2),
            timestampMs: fragmentDelay,
          ),
        );
      }
    }
    chunk
      ..sort((a, b) => a.timestampMs!.compareTo(b.timestampMs!))
      ..add(const DetokenizedWord.endOfChunk(timestampMs: window));
    take(merger.add(chunk));
  }
  take(merger.flush());
  return out;
}

List<_Word> _speech(List<String> texts) {
  final words = <_Word>[];
  var t = 2.0;
  for (final text in texts) {
    final duration = 2.0 + text.length * 0.8;
    words.add((text: text, onset: t, end: t + duration));
    t += duration + 1;
  }
  return words;
}

int _edits(List<String> a, List<String> b) {
  var d = List<int>.generate(b.length + 1, (j) => j);
  for (var i = 1; i <= a.length; i++) {
    final n = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      n[j] = math.min(
        math.min(d[j] + 1, n[j - 1] + 1),
        d[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1),
      );
    }
    d = n;
  }
  return d[b.length];
}

void main() {
  final random = math.Random(7);
  const vocabulary = [
    'the', 'and', 'a', 'to', 'of', 'that', 'had', 'is', 'this', 'in', 'it', //
    'satisfaction', 'necessary', 'contingency', 'resistance', 'mists',
  ];
  final texts = [
    for (var i = 0; i < 300; i++) vocabulary[random.nextInt(vocabulary.length)],
  ];
  final words = _speech(texts);

  test('a cut word\'s tail 6 frames into the window is dropped, and the next '
      'word kept', () {
    // ch1836 of LibriSpeech test-clean: "... satisfaction faction of ..."
    final merger = TimestampTextMerger(overlapRatio: 0.75);
    DetokenizedWord w(String text, int at) =>
        DetokenizedWord(text, timestampMs: at);
    const end = DetokenizedWord.endOfChunk(timestampMs: 63);
    final out = <String>[];
    void take(MergeResult? r) {
      if (r != null && r.confirmed.isNotEmpty) out.add(r.confirmed);
    }

    // Windows 15.75 frames apart: each word moves back by that much.
    take(
      merger.add([w('with', 20), w('great', 30), w('satisfaction', 44), end]),
    );
    take(merger.add([w('great', 14), w('satisfaction', 28), w('of', 41), end]));
    take(merger.add([w('satisfaction', 12), w('of', 25), w('mind', 33), end]));
    // The window starts inside "satisfaction": its tail at frame 6.
    take(merger.add([w('faction', 6), w('of', 10), w('mind', 17), end]));
    take(merger.flush());
    expect(out.join(' ').split(' '), [
      'with',
      'great',
      'satisfaction',
      'of',
      'mind',
    ]);
  });

  test('a new word that only shares letters with the cut word is kept', () {
    // "another" straddles the window start; "therapist" begins with its
    // last letters but is a word of its own, which the previous window
    // missed. Six frames in: past the narrow band, inside the wide one.
    final merger = TimestampTextMerger(overlapRatio: 0.75);
    DetokenizedWord w(String text, int at) =>
        DetokenizedWord(text, timestampMs: at);
    const end = DetokenizedWord.endOfChunk(timestampMs: 63);
    final out = <String>[];
    void take(MergeResult? r) {
      if (r != null && r.confirmed.isNotEmpty) out.add(r.confirmed);
    }

    take(merger.add([w('saw', 30), w('another', 44), end]));
    take(merger.add([w('saw', 14), w('another', 28), end]));
    take(merger.add([w('saw', 0), w('another', 12), end]));
    take(merger.add([w('therapist', 6), w('today', 20), end]));
    take(merger.flush());
    expect(out.join(' ').split(' '), contains('therapist'));
  });

  for (final overlap in [0.75, 0.5]) {
    // The merger's own errors on this text with no cut word heard at all
    // (repeated words in a row, merged by the timing tolerance).
    final baseline = _edits(texts, _run(words, overlap, -1));
    test('overlap $overlap: the clock alone costs few edits', () {
      expect(baseline, lessThanOrEqualTo(3));
    });
    for (final delay in [2, 4, 5, 6, 7]) {
      test('overlap $overlap, the tail of a cut word $delay frames into the '
          'window adds few errors', () {
        // Without the wide band, tails 5-7 frames in cost 18-38 edits here.
        // What is left are tails of long words whose onset lies further back
        // than the merger looks for the cut word.
        final out = _run(words, overlap, delay);
        expect(
          _edits(texts, out),
          lessThanOrEqualTo(baseline + 6),
          reason: out.join(' '),
        );
      });
    }
  }
}
