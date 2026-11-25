// Streaming speech on SpeechRecognizer / SpeechSynthesizer: a model that
// cannot stream says so and refuses, the catalog is off by default, and the
// value types hold their rules.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';

import '../catalog/catalog_fixtures.dart';

class _PlainRecognizer implements SpeechRecognizer {
  @override
  String? language;
  @override
  Future<String> transcribe(Uint8List pcm16kMono, {String? language}) async =>
      '';
  @override
  StreamingSttInfo? get streaming => null;
  @override
  Stream<TranscriptUpdate> transcribeStream(
    Stream<Uint8List> pcm16kMono, {
    String? language,
    TranscribeStreamOptions options = const TranscribeStreamOptions(),
  }) => Stream.error(UnsupportedError('this model does not stream'));
  @override
  Future<void> flush() => Future.error(StateError('no stream'));
  @override
  void addCloseListener(void Function() listener) {}
  @override
  Future<void> close() async {}
}

class _PlainSynth implements SpeechSynthesizer {
  @override
  int get sampleRate => 24000;
  @override
  Future<Uint8List> synthesize(String text) async => Uint8List(0);
  @override
  bool get supportsStreaming => false;
  @override
  Stream<SpeechChunk> synthesizeStream(String text) =>
      Stream.error(UnsupportedError('this model does not stream'));
  @override
  SpeechTextStream openTextStream() =>
      throw UnsupportedError('this model does not stream');
  @override
  void addCloseListener(void Function() listener) {}
  @override
  Future<void> close() async {}
}

void main() {
  test(
    'a recognizer that cannot stream says so and refuses on listen',
    () async {
      final SpeechRecognizer recognizer = _PlainRecognizer();
      expect(recognizer.streaming, isNull);
      final stream = recognizer.transcribeStream(const Stream.empty());
      await expectLater(stream, emitsError(isA<UnsupportedError>()));
      await expectLater(recognizer.flush(), throwsStateError);
    },
  );

  test('a synthesizer that cannot stream says so and refuses', () async {
    final SpeechSynthesizer synthesizer = _PlainSynth();
    expect(synthesizer.supportsStreaming, isFalse);
    await expectLater(
      synthesizer.synthesizeStream('hi'),
      emitsError(isA<UnsupportedError>()),
    );
    expect(synthesizer.openTextStream, throwsUnsupportedError);
  });

  test('catalog variants do not stream unless they say so', () {
    expect(TestStt().supportsStreaming, isFalse);
    expect(TestTts().supportsStreaming, isFalse);
  });

  test('defaults of the streaming value types', () {
    const options = TranscribeStreamOptions();
    expect(options.latency, StreamingLatency.lowLatency);
    expect(options.maxBufferedAudio, isNull);
    expect(
      options.maxBufferedAudioFor(const Duration(seconds: 5)),
      const Duration(seconds: 10),
    );
    expect(
      options.maxBufferedAudioFor(const Duration(seconds: 30)),
      const Duration(seconds: 30),
      reason: 'the default never refuses a model with a longer window',
    );
    expect(
      const TranscribeStreamOptions(
        maxBufferedAudio: Duration(seconds: 3),
      ).maxBufferedAudioFor(const Duration(seconds: 30)),
      const Duration(seconds: 3),
      reason: 'a set value is returned as is; transcribeStream checks it',
    );
    final update = TranscriptUpdate(
      confirmedDelta: ' hello',
      unconfirmed: 'wor',
      confirmedUntil: Duration(milliseconds: 800),
    );
    expect(update.endpoint, isFalse);
    expect(update.confirmedWords, isEmpty);
    expect(
      update,
      TranscriptUpdate(
        confirmedDelta: ' hello',
        unconfirmed: 'wor',
        confirmedUntil: const Duration(milliseconds: 800),
      ),
    );
    final words = [
      const WordTiming(
        word: 'a',
        start: 0,
        end: 1,
        audioStart: Duration.zero,
        audioEnd: Duration(milliseconds: 10),
      ),
    ];
    final withWords = TranscriptUpdate(
      confirmedDelta: 'a',
      unconfirmed: '',
      confirmedUntil: Duration.zero,
      confirmedWords: words,
    );
    words.clear();
    expect(withWords.confirmedWords, hasLength(1), reason: 'copied');
    expect(() => withWords.confirmedWords.clear(), throwsUnsupportedError);
    const word = WordTiming(
      word: 'hello',
      start: 1,
      end: 6,
      audioStart: Duration(milliseconds: 100),
      audioEnd: Duration(milliseconds: 500),
    );
    expect(
      word,
      const WordTiming(
        word: 'hello',
        start: 1,
        end: 6,
        audioStart: Duration(milliseconds: 100),
        audioEnd: Duration(milliseconds: 500),
      ),
    );
    expect(
      const SpeechStreamOverrunException(
        buffered: Duration(seconds: 11),
        limit: Duration(seconds: 10),
      ).toString(),
      contains('over the 0:00:10.000000 limit'),
    );
  });

  group('equality looks at every field', () {
    TranscriptUpdate update({
      String delta = ' a',
      String unconfirmed = 'b',
      int until = 100,
      List<WordTiming> words = const [],
      bool endpoint = false,
    }) => TranscriptUpdate(
      confirmedDelta: delta,
      unconfirmed: endpoint ? '' : unconfirmed,
      confirmedUntil: Duration(milliseconds: until),
      confirmedWords: words,
      endpoint: endpoint,
    );
    const word = WordTiming(
      word: 'a',
      start: 1,
      end: 2,
      audioStart: Duration(milliseconds: 10),
      audioEnd: Duration(milliseconds: 20),
    );

    test('TranscriptUpdate', () {
      final base = update();
      expect(update(), base);
      expect(update().hashCode, base.hashCode);
      for (final other in [
        update(delta: ' x'),
        update(unconfirmed: 'x'),
        update(until: 101),
        update(words: [word]),
        update(endpoint: true),
      ]) {
        expect(other, isNot(base), reason: '$other');
      }
      expect(update(words: [word]), update(words: [word]));
      expect(update(words: [word]).hashCode, update(words: [word]).hashCode);
    });

    test('WordTiming', () {
      expect(
        word.hashCode,
        const WordTiming(
          word: 'a',
          start: 1,
          end: 2,
          audioStart: Duration(milliseconds: 10),
          audioEnd: Duration(milliseconds: 20),
        ).hashCode,
      );
      for (final other in [
        const WordTiming(
          word: 'b',
          start: 1,
          end: 2,
          audioStart: Duration(milliseconds: 10),
          audioEnd: Duration(milliseconds: 20),
        ),
        const WordTiming(
          word: 'a',
          start: 2,
          end: 3,
          audioStart: Duration(milliseconds: 10),
          audioEnd: Duration(milliseconds: 20),
        ),
        const WordTiming(
          word: 'a',
          start: 1,
          end: 2,
          audioStart: Duration(milliseconds: 11),
          audioEnd: Duration(milliseconds: 20),
        ),
        const WordTiming(
          word: 'a',
          start: 1,
          end: 2,
          audioStart: Duration(milliseconds: 10),
          audioEnd: Duration(milliseconds: 21),
        ),
      ]) {
        expect(other, isNot(word), reason: '$other');
      }
      expect(word.toString(), allOf(contains('"a"'), contains('1-2')));
    });

    test('StreamingSttInfo', () {
      const info = StreamingSttInfo(
        kind: StreamingKind.windowed,
        window: Duration(seconds: 5),
      );
      expect(
        info.hashCode,
        const StreamingSttInfo(
          kind: StreamingKind.windowed,
          window: Duration(seconds: 5),
        ).hashCode,
      );
      expect(
        const StreamingSttInfo(
          kind: StreamingKind.incremental,
          window: Duration(seconds: 5),
        ),
        isNot(info),
      );
      expect(
        const StreamingSttInfo(
          kind: StreamingKind.windowed,
          window: Duration(seconds: 4),
        ),
        isNot(info),
      );
      expect(info.toString(), allOf(contains('windowed'), contains('0:00:05')));
    });

    test('TranscribeStreamOptions', () {
      const options = TranscribeStreamOptions(
        maxBufferedAudio: Duration(seconds: 20),
      );
      expect(
        options.hashCode,
        const TranscribeStreamOptions(
          maxBufferedAudio: Duration(seconds: 20),
        ).hashCode,
      );
      expect(
        const TranscribeStreamOptions(
          latency: StreamingLatency.balanced,
          maxBufferedAudio: Duration(seconds: 20),
        ),
        isNot(options),
      );
      expect(const TranscribeStreamOptions(), isNot(options));
      expect(options.toString(), contains('lowLatency'));
    });
  });

  group('value types refuse what cannot be (asserts)', () {
    test('TranscriptUpdate', () {
      expect(
        () => TranscriptUpdate(
          confirmedDelta: '',
          unconfirmed: 'x',
          confirmedUntil: Duration.zero,
          endpoint: true,
        ),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => TranscriptUpdate(
          confirmedDelta: '',
          unconfirmed: '',
          confirmedUntil: const Duration(milliseconds: -1),
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('WordTiming', () {
      WordTiming make(String word, int start, int end) => WordTiming(
        word: word,
        start: start,
        end: end,
        audioStart: Duration.zero,
        audioEnd: Duration.zero,
      );
      expect(() => make('a', -1, 0), throwsA(isA<AssertionError>()));
      expect(() => make('ab', 3, 2), throwsA(isA<AssertionError>()));
      expect(() => make('abc', 0, 2), throwsA(isA<AssertionError>()));
      expect(make('ab', 3, 5).end, 5);
    });

    test('SpeechChunk', () {
      SpeechChunk make({int bytes = 4, int rate = 24000, int index = 0}) =>
          SpeechChunk(pcm: Uint8List(bytes), sampleRate: rate, index: index);
      expect(() => make(rate: 0), throwsA(isA<AssertionError>()));
      expect(() => make(index: -1), throwsA(isA<AssertionError>()));
      expect(() => make(bytes: 3), throwsA(isA<AssertionError>()));
      expect(make().toString(), allOf(contains('#0'), contains('2 samples')));
    });
  });

  test('SpeechChunk copies its words and keeps them unmodifiable', () {
    final words = [
      const WordTiming(
        word: 'a',
        start: 0,
        end: 1,
        audioStart: Duration.zero,
        audioEnd: Duration(milliseconds: 5),
      ),
    ];
    final chunk = SpeechChunk(
      pcm: Uint8List(2),
      sampleRate: 24000,
      index: 0,
      words: words,
    );
    words.clear();
    expect(chunk.words, hasLength(1));
    expect(() => chunk.words.clear(), throwsUnsupportedError);
  });
}
