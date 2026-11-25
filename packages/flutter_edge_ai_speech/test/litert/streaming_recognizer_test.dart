// LiteRtStreamingSpeechRecognizer over a fake engine inside the real STT
// worker: the stream's claim, input, queue, flush, close and overrun rules,
// and that windowed text comes out once and in order. No model; the windows
// and the merger are the real ones.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart'
    show LiteRtSpeechModels;
import 'package:flutter_edge_ai_speech/src/litert/litert_speech_recognizer.dart';
import 'package:flutter_edge_ai_speech/src/litert/stt_core.dart'
    show CtcWindowTokens;
import 'package:flutter_edge_ai_speech/src/litert/stt_worker.dart';
import 'package:flutter_edge_ai_speech/src/model/stt_model_profile.dart';
import 'package:flutter_test/flutter_test.dart';

import 'worker_test_support.dart';

/// A word is a run of samples at level `id * 1000` (id 1..9) at a 16 kHz
/// position; the fake decoder reports one token per run, at its first
/// sample's frame (a frame is 1,280 samples, 80 ms, as Parakeet's encoder).
final class _FakeEngine implements SttWorkerEngine {
  _FakeEngine(this._config);
  final String _config;

  @override
  Future<void> load() async {}

  @override
  String transcribe(Float32List samples, {String? language}) =>
      'batch ${samples.length}';

  @override
  CtcWindowTokens ctcWindow(
    Float32List window, {
    required int validSamples,
    required double startFraction,
  }) {
    final (_, log) = parseFakeConfig(_config);
    appendLogLine(log, 'window');
    if (_config.startsWith('gate')) blockUntilReleased(log);
    const frame = 1280;
    final frames = window.length ~/ frame;
    final first = (startFraction * frames).floor();
    final ids = <int>[];
    final at = <int>[];
    var previous = 0;
    for (var i = 0; i < validSamples; i++) {
      final v = (window[i] * 32768 / 1000).round();
      if (v != previous && v >= 1 && v <= 9) {
        final f = i ~/ frame;
        if (f >= first) {
          ids.add(v);
          at.add(f - first);
        }
      }
      previous = v;
    }
    return CtcWindowTokens(
      Int32List.fromList(ids),
      Int32List.fromList(at),
      frames - first,
    );
  }

  @override
  void dispose() {}
}

SttWorkerEngine _fake({
  required String modelPath,
  required String tokenizerPath,
  required SttModelProfile profile,
  PreferredBackend? backend,
}) => _FakeEngine(modelPath);

/// [words] (token ids 1..9) spoken one every [spacing] samples, each 0.2 s
/// long, as 16-bit PCM; [seconds] long.
Uint8List _speech(List<int> words, {int spacing = 8000, double seconds = 0}) {
  final total = seconds > 0
      ? (seconds * 16000).round()
      : words.length * spacing + 16000;
  final data = ByteData(total * 2);
  for (var w = 0; w < words.length; w++) {
    final start = w * spacing + 4000;
    for (var i = start; i < start + 3200 && i < total; i++) {
      data.setInt16(i * 2, words[w] * 1000, Endian.little);
    }
  }
  return data.buffer.asUint8List();
}

Stream<Uint8List> _chunks(Uint8List bytes, int size) async* {
  for (var i = 0; i < bytes.length; i += size) {
    yield Uint8List.sublistView(
      bytes,
      i,
      i + size > bytes.length ? bytes.length : i + size,
    );
  }
}

/// The whole transcript a stream's updates add up to.
String _transcript(List<TranscriptUpdate> updates) =>
    updates.map((u) => u.confirmedDelta).join().trim();

void main() {
  late Directory dir;
  late String tokenizerPath;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('stt_stream_');
    tokenizerPath = '${dir.path}/tokenizer.json';
    File(tokenizerPath).writeAsStringSync(
      jsonEncode({
        'model': {
          'vocab': {'<unk>': 0, for (var i = 1; i <= 9; i++) '▁w$i': i},
        },
      }),
    );
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<LiteRtSpeechRecognizer> create({
    SttModelProfile profile = const SttModelProfile.parakeet(),
    String config = 'fast',
  }) => LiteRtSpeechRecognizer.create(
    profile: profile,
    modelPath: config,
    tokenizerPath: tokenizerPath,
    engineFactory: _fake,
  );

  test('Parakeet streams, Whisper does not', () async {
    final parakeet = await create();
    addTearDown(parakeet.close);
    expect(parakeet.streaming, isNotNull);
    expect(parakeet.streaming!.kind, StreamingKind.windowed);
    expect(parakeet.streaming!.window, const Duration(seconds: 5));
    final whisper = await create(profile: const SttModelProfile.whisper());
    addTearDown(whisper.close);
    expect(whisper.streaming, isNull);
    await expectLater(
      whisper.transcribeStream(const Stream.empty()),
      emitsError(isA<UnsupportedError>()),
    );
  });

  test('the catalog says a build streams exactly when the recognizer it '
      'loads into streams', () async {
    var checked = 0;
    for (final model in LiteRtSpeechModels.stt) {
      for (final variant in model.variants) {
        if (variant.npuTarget != null) {
          expect(variant.supportsStreaming, isFalse, reason: variant.id);
          continue;
        }
        final recognizer = await create(
          profile: SttModelProfile.forType(variant.type),
        );
        expect(
          recognizer.streaming != null,
          variant.supportsStreaming,
          reason: variant.id,
        );
        await recognizer.close();
        checked++;
      }
    }
    expect(checked, greaterThan(0));
    for (final model in LiteRtSpeechModels.tts) {
      for (final variant in model.variants) {
        expect(variant.supportsStreaming, isFalse, reason: variant.id);
      }
    }
  });

  test(
    'a long stream comes out once, in order, whatever the chunking',
    () async {
      final recognizer = (await create());
      addTearDown(recognizer.close);
      final words = [for (var i = 0; i < 40; i++) 1 + i % 9];
      final expected = [for (final w in words) 'w$w'].join(' ');
      final pcm = _speech(words);
      for (final chunk in [3200, 3333, 32000]) {
        // Fed far faster than real time: lift the cap on audio waiting.
        final updates = await recognizer
            .transcribeStream(
              _chunks(pcm, chunk),
              options: const TranscribeStreamOptions(
                maxBufferedAudio: Duration(minutes: 10),
              ),
            )
            .toList();
        expect(_transcript(updates), expected, reason: 'chunk $chunk');
        expect(updates.last.endpoint, isTrue);
        expect(updates.last.unconfirmed, isEmpty);
        expect(updates.where((u) => u.endpoint), hasLength(1));
        expect(
          updates.any((u) => !u.endpoint && u.unconfirmed.isNotEmpty),
          isTrue,
          reason: 'partial text before the input ends',
        );
        for (var k = 1; k < updates.length; k++) {
          expect(
            updates[k].confirmedUntil >= updates[k - 1].confirmedUntil,
            isTrue,
            reason: 'confirmedUntil never goes back',
          );
        }
      }
    },
  );

  test('confirmedUntil is a lower bound: every word that starts before it '
      'is already confirmed', () async {
    final recognizer = (await create());
    addTearDown(recognizer.close);
    const spacing = 8000;
    final words = [for (var i = 0; i < 30; i++) 1 + i % 9];
    final updates = await recognizer
        .transcribeStream(
          _chunks(_speech(words, spacing: spacing), 1600),
          options: const TranscribeStreamOptions(
            maxBufferedAudio: Duration(minutes: 10),
          ),
        )
        .toList();
    var confirmedWords = 0;
    var sawBound = false;
    for (final u in updates) {
      confirmedWords += u.confirmedDelta.trim().isEmpty
          ? 0
          : u.confirmedDelta.trim().split(' ').length;
      final until = u.confirmedUntil.inMicroseconds * 16000 ~/ 1000000;
      if (!u.endpoint && until > 0) sawBound = true;
      for (var w = 0; w < words.length; w++) {
        if (w * spacing + 4000 < until) {
          expect(
            w < confirmedWords,
            isTrue,
            reason:
                'word $w starts before ${u.confirmedUntil} but only '
                '$confirmedWords words are confirmed',
          );
        }
      }
    }
    expect(sawBound, isTrue, reason: 'the bound moves before the end');
  });

  test('a small chunk that changes nothing sends no update', () async {
    final recognizer = (await create());
    addTearDown(recognizer.close);
    final words = [for (var i = 0; i < 12; i++) 1 + i % 9];
    // 20 ms chunks: most complete no window.
    final pcm = _speech(words);
    final updates = await recognizer
        .transcribeStream(
          _chunks(pcm, 640),
          options: const TranscribeStreamOptions(
            maxBufferedAudio: Duration(minutes: 10),
          ),
        )
        .toList();
    expect(updates.length, lessThan(pcm.length ~/ 640 ~/ 4));
    for (var k = 1; k < updates.length; k++) {
      expect(updates[k], isNot(updates[k - 1]), reason: 'update $k repeats');
    }
    expect(_transcript(updates), [for (final w in words) 'w$w'].join(' '));
  });

  test('odd-sized chunks carry the half sample to the next chunk', () async {
    final recognizer = (await create());
    addTearDown(recognizer.close);
    final words = [1, 2, 3, 4];
    final updates = await recognizer
        .transcribeStream(
          _chunks(_speech(words), 1001),
          options: const TranscribeStreamOptions(
            maxBufferedAudio: Duration(minutes: 10),
          ),
        )
        .toList();
    expect(_transcript(updates), 'w1 w2 w3 w4');
  });

  test('balanced latency gives the same text', () async {
    final recognizer = (await create());
    addTearDown(recognizer.close);
    final words = [for (var i = 0; i < 25; i++) 9 - i % 9];
    final updates = await recognizer
        .transcribeStream(
          _chunks(_speech(words), 4000),
          options: const TranscribeStreamOptions(
            latency: StreamingLatency.balanced,
            maxBufferedAudio: Duration(minutes: 10),
          ),
        )
        .toList();
    expect(_transcript(updates), [for (final w in words) 'w$w'].join(' '));
  });

  test('one stream at a time; one never listened to holds nothing', () async {
    final recognizer = (await create());
    addTearDown(recognizer.close);
    recognizer.transcribeStream(const Stream.empty()); // never listened
    final input = StreamController<Uint8List>();
    final first = recognizer.transcribeStream(input.stream).toList();
    await Future<void>.delayed(Duration.zero);
    await expectLater(
      recognizer.transcribeStream(const Stream.empty()).toList(),
      throwsStateError,
    );
    await input.close();
    await first;
    expect(
      await recognizer.transcribeStream(const Stream.empty()).toList(),
      hasLength(1), // the endpoint update
    );
  });

  test(
    'a language on a model without one ends the stream with ArgumentError',
    () async {
      final recognizer = (await create());
      addTearDown(recognizer.close);
      await expectLater(
        recognizer
            .transcribeStream(const Stream.empty(), language: 'de')
            .toList(),
        throwsArgumentError,
      );
    },
  );

  test('maxBufferedAudio below the window throws at the call', () async {
    final recognizer = (await create());
    addTearDown(recognizer.close);
    expect(
      () => recognizer.transcribeStream(
        const Stream.empty(),
        options: const TranscribeStreamOptions(
          maxBufferedAudio: Duration(seconds: 2),
        ),
      ),
      throwsArgumentError,
    );
  });

  test('flush closes an utterance and the stream goes on', () async {
    final recognizer = (await create());
    addTearDown(recognizer.close);
    final input = StreamController<Uint8List>();
    final updates = <TranscriptUpdate>[];
    final done = recognizer
        .transcribeStream(input.stream)
        .listen(updates.add)
        .asFuture<void>();
    input.add(_speech([1, 2, 3]));
    await Future<void>.delayed(Duration.zero);
    await recognizer.flush();
    expect(updates.last.endpoint, isTrue);
    expect(_transcript(updates), 'w1 w2 w3');
    final afterFlush = updates.length;
    input.add(_speech([4, 5]));
    await input.close();
    await done;
    expect(_transcript(updates.sublist(afterFlush)), 'w4 w5');
    expect(updates.last.endpoint, isTrue);
    await expectLater(recognizer.flush(), throwsStateError);
  });

  test('transcribe during a stream waits its turn and works', () async {
    final recognizer = await create();
    addTearDown(recognizer.close);
    final input = StreamController<Uint8List>();
    final stream = recognizer.transcribeStream(input.stream).toList();
    input.add(_speech([1, 2], seconds: 6));
    expect(await recognizer.transcribe(Uint8List(200)), 'batch 100');
    await input.close();
    expect(_transcript(await stream), 'w1 w2');
  });

  test('close ends a running stream with a StateError', () async {
    final recognizer = (await create());
    final input = StreamController<Uint8List>();
    final stream = recognizer.transcribeStream(input.stream).toList();
    input.add(_speech([1], seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final ended = expectLater(stream, throwsStateError);
    await recognizer.close();
    await ended;
    await input.close();
  });

  test('closing the recognizer during a flush fails the flush', () async {
    final log = gatedLog(dir, 'gate');
    final recognizer = (await create(config: 'gate@${log.path}'));
    final input = StreamController<Uint8List>();
    final stream = recognizer.transcribeStream(input.stream).toList();
    final ended = expectLater(stream, throwsStateError);
    input.add(_speech([1], seconds: 5));
    // The first window blocks; the flush waits behind it.
    await waitForLine(log, 'window');
    final flushed = expectLater(recognizer.flush(), throwsStateError);
    final closing = recognizer.close();
    release(log);
    await flushed;
    await ended;
    await closing;
    await input.close();
  });

  test('audio piling up behind a slow model fails with an overrun', () async {
    final log = gatedLog(dir, 'gate');
    final recognizer = (await create(config: 'gate@${log.path}'));
    addTearDown(recognizer.close);
    final input = StreamController<Uint8List>();
    final stream = recognizer
        .transcribeStream(
          input.stream,
          options: const TranscribeStreamOptions(
            maxBufferedAudio: Duration(seconds: 6),
          ),
        )
        .toList();
    // The first window blocks in "native" code; 7 s more audio arrives.
    input.add(_speech([1], seconds: 5));
    await waitForLine(log, 'window');
    input.add(_speech([2], seconds: 7));
    await expectLater(stream, throwsA(isA<SpeechStreamOverrunException>()));
    release(log);
    await input.close();
  });

  test('cancelling stops the input; the recognizer is free after the window '
      'in flight', () async {
    final log = gatedLog(dir, 'gate');
    final recognizer = (await create(config: 'gate@${log.path}'));
    addTearDown(recognizer.close);
    final cancelled = Completer<void>();
    final input = StreamController<Uint8List>(onCancel: cancelled.complete);
    final sub = recognizer.transcribeStream(input.stream).listen((_) {});
    input.add(_speech([1], seconds: 5));
    await waitForLine(log, 'window');
    final cancelDone = sub.cancel();
    await cancelled.future;
    release(log);
    await cancelDone;
    expect(
      await recognizer.transcribeStream(const Stream.empty()).toList(),
      hasLength(1),
    );
  });
}
