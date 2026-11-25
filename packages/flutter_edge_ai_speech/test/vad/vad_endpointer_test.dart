import 'package:flutter_edge_ai_speech/src/vad/vad_endpointer.dart';
import 'package:flutter_edge_ai_speech/src/vad/vad_event.dart';
import 'package:flutter_edge_ai_speech/src/vad/vad_options.dart';
import 'package:flutter_test/flutter_test.dart';

/// Milliseconds of [frames] 32 ms frames.
Duration ms(int milliseconds) => Duration(milliseconds: milliseconds);

/// Feeds [probabilities] and returns every event, with the frame index that
/// caused it.
List<(int, VadEvent)> run(
  VadEndpointer endpointer,
  List<double> probabilities, {
  bool finish = true,
  int? totalSamples,
}) {
  final out = <(int, VadEvent)>[];
  for (var i = 0; i < probabilities.length; i++) {
    for (final e in endpointer.add(probabilities[i])) {
      out.add((i, e));
    }
  }
  if (finish) {
    for (final e in endpointer.finish(totalSamples: totalSamples)) {
      out.add((probabilities.length, e));
    }
  }
  return out;
}

List<double> frames(int count, double p) => List.filled(count, p);

void main() {
  // 32 ms frames. Defaults: minSpeech 250 ms (8 frames = 256 ms), minSilence
  // 600 ms (19 frames = 608 ms), pad 30 ms, max 30 s.
  const options = VadOptions();

  test('silence alone causes nothing', () {
    expect(run(VadEndpointer(options), frames(100, 0.02)), isEmpty);
  });

  test('speech is reported once it has lasted minSpeech, timed back to its '
      'onset minus the pad', () {
    final events = run(VadEndpointer(options), [
      ...frames(10, 0.02),
      ...frames(20, 0.9),
    ], finish: false);
    expect(events, hasLength(1));
    final (index, start) = events.single;
    // Onset at frame 10 = 320 ms; 8 frames later (256 ms) it is confirmed.
    expect(index, 17);
    expect((start as VadSpeechStart).start, ms(290));
  });

  test('a burst shorter than minSpeech is dropped', () {
    expect(
      run(VadEndpointer(options), [
        ...frames(10, 0.02),
        ...frames(5, 0.9), // 160 ms
        ...frames(40, 0.02),
      ]),
      isEmpty,
    );
  });

  test('minSilence of silence ends the utterance at the silence start plus the '
      'pad', () {
    final events = run(VadEndpointer(options), [
      ...frames(10, 0.02),
      ...frames(30, 0.9), // speech frames 10..39
      ...frames(30, 0.02), // silence from frame 40 = 1280 ms
    ]);
    expect(events.map((e) => e.$2.runtimeType), [VadSpeechStart, VadSpeechEnd]);
    final (index, endEvent) = events.last;
    final end = endEvent as VadSpeechEnd;
    expect(end.reason, VadEndReason.silence);
    expect(end.start, ms(290));
    expect(end.end, ms(1280 + 30));
    // 19 silent frames (608 ms) are needed: frames 40..58.
    expect(index, 58);
  });

  test('a pause shorter than minSilence does not end the utterance', () {
    final events = run(VadEndpointer(options), [
      ...frames(30, 0.9),
      ...frames(10, 0.02), // 320 ms pause
      ...frames(30, 0.9),
      ...frames(30, 0.02),
    ]);
    expect(events.map((e) => e.$2).whereType<VadSpeechEnd>(), hasLength(1));
    expect(events.map((e) => e.$2).whereType<VadSpeechStart>(), hasLength(1));
  });

  test('probabilities between the two thresholds keep the silence mark: '
      'hysteresis', () {
    // Silence starts at frame 30, then the voice hovers at 0.4 (below 0.5,
    // above 0.35): the mark stays, so the utterance still ends.
    final events = run(VadEndpointer(options), [
      ...frames(30, 0.9),
      0.1,
      ...frames(30, 0.4),
    ], finish: false);
    final end = events.last.$2 as VadSpeechEnd;
    expect(end.end, ms(30 * 32 + 30));
    // ...while hovering alone, right after speech, never marks silence.
    final hovering = run(VadEndpointer(options), [
      ...frames(30, 0.9),
      ...frames(60, 0.4),
    ], finish: false);
    expect(hovering.map((e) => e.$2).whereType<VadSpeechEnd>(), isEmpty);
  });

  test('a frame at the threshold clears the silence mark', () {
    final events = run(VadEndpointer(options), [
      ...frames(30, 0.9),
      ...frames(15, 0.02),
      0.5,
      ...frames(15, 0.02),
    ], finish: false);
    expect(events.map((e) => e.$2).whereType<VadSpeechEnd>(), isEmpty);
  });

  test('maxUtterance cuts a long utterance and speech starts a new one', () {
    const short = VadOptions(maxUtterance: Duration(seconds: 1));
    final events = run(VadEndpointer(short), frames(80, 0.9));
    final ends = events.map((e) => e.$2).whereType<VadSpeechEnd>().toList();
    final starts = events.map((e) => e.$2).whereType<VadSpeechStart>();
    // Onset 0, cut at the first frame end >= 1 s: frame 31 ends at 1024 ms.
    // The next onset is frame 32 (1024 ms), cut after frame 63 (2048 ms);
    // the third runs from frame 64 to the end of input (2560 ms).
    expect(starts.map((s) => s.start), [ms(0), ms(1024 - 30), ms(2048 - 30)]);
    expect(ends.map((e) => e.reason), [
      VadEndReason.maxUtterance,
      VadEndReason.maxUtterance,
      VadEndReason.inputEnded,
    ]);
    expect(ends.map((e) => e.end), [ms(1024), ms(2048), ms(2560)]);
  });

  test('the end of input ends speech at the audio received', () {
    final events = run(
      VadEndpointer(options),
      frames(20, 0.9),
      totalSamples: 19 * 512 + 100,
    );
    final end = events.last.$2 as VadSpeechEnd;
    expect(end.reason, VadEndReason.inputEnded);
    expect(end.end, vadSamplesToDuration(19 * 512 + 100));
  });

  test(
    'the end of input during a pause ends speech at the pause plus the pad',
    () {
      final events = run(VadEndpointer(options), [
        ...frames(20, 0.9),
        ...frames(5, 0.02),
      ]);
      final end = events.last.$2 as VadSpeechEnd;
      expect(end.end, ms(20 * 32 + 30));
    },
  );

  test('the start is never before 0 and the end never after the audio', () {
    final events = run(VadEndpointer(options), frames(10, 0.9));
    expect((events.first.$2 as VadSpeechStart).start, Duration.zero);
    expect((events.last.$2 as VadSpeechEnd).end, ms(320));
  });

  test('an unconfirmed burst at the end of input is dropped', () {
    expect(run(VadEndpointer(options), frames(4, 0.9)), isEmpty);
  });

  test('add after finish throws; finish twice is a no-op', () {
    final endpointer = VadEndpointer(options)..add(0.9);
    endpointer.finish();
    expect(endpointer.finish(), isEmpty);
    expect(() => endpointer.add(0.1), throwsStateError);
  });

  test('a value that is not a probability throws', () {
    final endpointer = VadEndpointer(options);
    expect(() => endpointer.add(double.nan), throwsArgumentError);
    expect(() => endpointer.add(1.5), throwsArgumentError);
    expect(() => endpointer.add(-0.1), throwsArgumentError);
  });

  group('VadOptions', () {
    test(
      'the negative threshold defaults to threshold - 0.15, at least 0.01',
      () {
        expect(
          const VadOptions().effectiveNegativeThreshold,
          closeTo(0.35, 1e-9),
        );
        expect(
          const VadOptions(threshold: 0.1).effectiveNegativeThreshold,
          0.01,
        );
      },
    );

    test('validate refuses values that cannot work', () {
      for (final bad in [
        const VadOptions(threshold: 0),
        const VadOptions(threshold: 1),
        const VadOptions(negativeThreshold: 0.6),
        const VadOptions(negativeThreshold: 0),
        const VadOptions(minSilence: Duration(milliseconds: -1)),
        const VadOptions(maxUtterance: Duration(milliseconds: 250)),
      ]) {
        expect(bad.validate, throwsArgumentError, reason: '$bad');
      }
      const VadOptions().validate();
    });
  });
}
