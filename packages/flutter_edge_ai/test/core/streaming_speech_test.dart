// The streaming capability interfaces: found through `asStreaming`, absent on
// a plain recognizer or synthesizer, and off by default in the catalog.
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
  void addCloseListener(void Function() listener) {}
  @override
  Future<void> close() async {}
}

class _StreamingRecognizer extends _PlainRecognizer
    implements StreamingSpeechRecognizer {
  @override
  Stream<TranscriptUpdate> transcribeStream(
    Stream<Uint8List> pcm16kMono, {
    String? language,
    TranscribeStreamOptions options = const TranscribeStreamOptions(),
  }) => const Stream.empty();
  @override
  Future<void> flush() async {}
  @override
  StreamingSttInfo get streaming => const StreamingSttInfo(
    kind: StreamingKind.windowed,
    window: Duration(seconds: 5),
  );
}

class _PlainSynth implements SpeechSynthesizer {
  @override
  int get sampleRate => 24000;
  @override
  Future<Uint8List> synthesize(String text) async => Uint8List(0);
  @override
  void addCloseListener(void Function() listener) {}
  @override
  Future<void> close() async {}
}

class _StreamingSynth extends _PlainSynth
    implements StreamingSpeechSynthesizer {
  @override
  Stream<SpeechChunk> synthesizeStream(String text) => const Stream.empty();
  @override
  SpeechTextStream openTextStream() => throw UnimplementedError();
}

void main() {
  test('asStreaming finds a streaming recognizer and is null otherwise', () {
    final SpeechRecognizer streaming = _StreamingRecognizer();
    final SpeechRecognizer plain = _PlainRecognizer();
    expect(streaming.asStreaming, same(streaming));
    expect(streaming.asStreaming!.streaming.kind, StreamingKind.windowed);
    expect(plain.asStreaming, isNull);
  });

  test('asStreaming finds a streaming synthesizer and is null otherwise', () {
    final SpeechSynthesizer streaming = _StreamingSynth();
    final SpeechSynthesizer plain = _PlainSynth();
    expect(streaming.asStreaming, same(streaming));
    expect(plain.asStreaming, isNull);
  });

  test('catalog variants do not stream unless they say so', () {
    expect(TestStt().streaming, isFalse);
    expect(TestTts().streaming, isFalse);
  });

  test('defaults of the streaming value types', () {
    const options = TranscribeStreamOptions();
    expect(options.latency, StreamingLatency.lowLatency);
    expect(options.maxBufferedAudio, const Duration(seconds: 10));
    const update = TranscriptUpdate(
      confirmedDelta: ' hello',
      unconfirmed: 'wor',
      confirmedUntil: Duration(milliseconds: 800),
    );
    expect(update.endpoint, isFalse);
    expect(update.confirmedWords, isEmpty);
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
        Duration(seconds: 11),
        Duration(seconds: 10),
      ).toString(),
      contains('over the 0:00:10.000000 limit'),
    );
  });
}
