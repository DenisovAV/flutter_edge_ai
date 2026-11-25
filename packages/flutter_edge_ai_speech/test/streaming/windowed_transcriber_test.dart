// WindowedTranscriber's own rules over a recording runner: which windows run,
// how a short final chunk is padded or shifted back, and that the shift back
// splices the samples before the kept overlap instead of repeating it.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_edge_ai_speech/src/streaming/detokenizer.dart';
import 'package:flutter_edge_ai_speech/src/streaming/windowed_transcriber.dart';
import 'package:flutter_test/flutter_test.dart';

/// One run of the runner, as the transcriber asked for it.
typedef _Run = ({Float32List window, int validSamples, double startFraction});

Float32List _ramp(int from, int count) =>
    Float32List.fromList([for (var i = 0; i < count; i++) (from + i) * 1.0]);

void main() {
  group('shiftShortChunkBack', () {
    test(
      'splices the samples before the overlap the remainder starts with',
      () {
        // Window 10; the previous window holds samples 10..19; the remainder
        // starts with the windower's kept overlap (17..19) and adds 20..22.
        final previous = _ramp(10, 10);
        final remainder = _ramp(17, 6);
        final shifted = shiftShortChunkBack(remainder, previous);
        expect(shifted.window, _ramp(13, 10)); // 13..16, then 17..22
        expect(shifted.startFraction, 0.4);
      },
    );

    test('with no overlap, takes the end of the previous window', () {
      final shifted = shiftShortChunkBack(_ramp(100, 4), _ramp(0, 10));
      expect(shifted.window.sublist(0, 6), _ramp(4, 6));
      expect(shifted.window.sublist(6), _ramp(100, 4));
    });

    test('a remainder as long as the window throws', () {
      expect(
        () => shiftShortChunkBack(_ramp(0, 10), _ramp(0, 10)),
        throwsArgumentError,
      );
    });
  });

  group('WindowedTranscriber', () {
    late List<_Run> runs;
    late WindowedTranscriber transcriber;

    setUp(() {
      runs = [];
      transcriber = WindowedTranscriber(
        windowSamples: 100,
        overlapRatio: 0.75,
        tokenIdsToUtf8: (ids, {required skipSpecialTokens}) =>
            utf8.encode(ids.map((i) => 'w$i').join(' ')),
        runWindow: (window, {required validSamples, required startFraction}) {
          runs.add((
            window: Float32List.fromList(window),
            validSamples: validSamples,
            startFraction: startFraction,
          ));
          return Future.value([const DecodedToken.endOfChunk(timestampMs: 10)]);
        },
      );
    });

    test('every window the model gets is a whole window', () async {
      await transcriber.add(_ramp(1, 60));
      await transcriber.add(_ramp(61, 90));
      await transcriber.finish();
      expect(runs, isNotEmpty);
      for (final run in runs) {
        expect(run.window, hasLength(100));
      }
    });

    test('warm-start prefixes are zero-padded with their length as the '
        'valid part', () async {
      await transcriber.add(_ramp(1, 30));
      expect(runs, hasLength(1));
      expect(runs.single.validSamples, 30);
      expect(runs.single.window.sublist(30), everyElement(0));
      expect(runs.single.startFraction, 0);
    });

    test('a short final chunk after a full window is shifted back when a '
        'sixth of the window or more is missing', () async {
      // Full window 1..100; the windower keeps 26..100 and the remainder is
      // 26..105 (80 samples, 20 missing >= 100 / 6). It starts with the kept
      // overlap 26..100, so the splice takes 6..25 before it.
      await transcriber.add(_ramp(1, 105));
      runs.clear();
      await transcriber.finish();
      final last = runs.last;
      expect(last.validSamples, 100);
      expect(last.startFraction, closeTo(0.2, 1e-9));
      expect(last.window, _ramp(6, 100));
    });

    test('a final chunk missing less than a sixth is padded instead', () async {
      // Full window 1..100, then 95 more samples: the remainder holds the 75
      // kept plus 20 new = 95, 5 missing (< 100 / 6).
      await transcriber.add(_ramp(1, 120));
      runs.clear();
      await transcriber.finish();
      final last = runs.last;
      expect(last.startFraction, 0);
      expect(last.validSamples, lessThan(100));
      expect(last.window.sublist(last.validSamples), everyElement(0));
    });
  });

  test('confirmedUntil is a lower bound over many word layouts, windows '
      'starting between two frames', () async {
    // 100-sample windows of 10 frames (10 samples each), overlap 0.75: the
    // windows start every 25 samples, 2.5 frames, which the merger rounds.
    // Samples carry their own position (sample i is i + 1), so the runner
    // knows where each window starts; a word is a token at its frame. Many
    // seeded layouts, as a word just before a window start is what breaks
    // an unrounded bound.
    final random = Random(3);
    for (var layout = 0; layout < 300; layout++) {
      final wordsAt = <int>[];
      for (
        var at = random.nextInt(12);
        at < 290;
        at += 11 + random.nextInt(30)
      ) {
        wordsAt.add(at);
      }
      final transcriber = WindowedTranscriber(
        windowSamples: 100,
        overlapRatio: 0.75,
        tokenIdsToUtf8: (ids, {required skipSpecialTokens}) =>
            utf8.encode(ids.map((i) => ' w$i').join()),
        runWindow: (window, {required validSamples, required startFraction}) {
          final origin = window[0].round() - 1;
          final first = (startFraction * 10).floor();
          return Future.value([
            for (var k = 0; k < wordsAt.length; k++)
              if (wordsAt[k] >= origin &&
                  wordsAt[k] < origin + validSamples &&
                  (wordsAt[k] - origin) ~/ 10 >= first)
                DecodedToken(
                  k + 1,
                  timestampMs: (wordsAt[k] - origin) ~/ 10 - first,
                ),
            DecodedToken.endOfChunk(timestampMs: 10 - first),
          ]);
        },
      );
      var confirmed = 0;
      for (var i = 0; i < 300; i += 25) {
        final result = await transcriber.add(_ramp(i + 1, 25));
        if (result.confirmed.isNotEmpty) {
          confirmed += result.confirmed.trim().split(RegExp(r'\s+')).length;
        }
        for (var k = 0; k < wordsAt.length; k++) {
          if (wordsAt[k] < result.confirmedUntil && k >= confirmed) {
            fail(
              'layout $layout $wordsAt: w${k + 1} at ${wordsAt[k]} is before '
              'confirmedUntil ${result.confirmedUntil}, but only $confirmed '
              'words are confirmed',
            );
          }
        }
      }
    }
  });
}
