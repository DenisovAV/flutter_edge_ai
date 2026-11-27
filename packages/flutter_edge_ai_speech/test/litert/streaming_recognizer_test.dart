// LiteRtStreamingSpeechRecognizer over a fake engine inside the real STT
// worker: the stream's claim, input, queue, flush, close and overrun rules,
// and that windowed text comes out once and in order. No model; the windows
// and the merger are the real ones.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
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
    final (mode, log) = parseFakeConfig(_config);
    appendLogLine(log, 'window');
    if (mode == 'dies') Isolate.exit();
    // `gate`: every window waits for the release; `gate2`: from the second
    // window on.
    final windowsRun = log == null
        ? 0
        : '\n'.allMatches(File(log).readAsStringSync()).length;
    if (mode == 'gate' || (mode == 'gate2' && windowsRun >= 2)) {
      blockUntilReleased(log);
    }
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

  group('the transcribeStream contract, one test per rule', () {
    test(
      'a paused stream keeps reading and analysing; its updates wait',
      () async {
        final log = File('${dir.path}/paused.log');
        final recognizer = await create(config: 'fast@${log.path}');
        addTearDown(recognizer.close);
        final input = StreamController<Uint8List>();
        final updates = <TranscriptUpdate>[];
        final ended = Completer<void>();
        final sub = recognizer
            .transcribeStream(input.stream)
            .listen(updates.add, onDone: ended.complete);
        sub.pause();
        // 8 s while paused, well inside the default 10 s limit only because
        // the model keeps up: windows run although nobody listens.
        for (final chunk in await _chunks(
          _speech([1, 2, 3, 4]),
          32000,
        ).toList()) {
          input.add(chunk);
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        while (!log.existsSync() ||
            '\n'.allMatches(log.readAsStringSync()).length < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(updates, isEmpty, reason: 'paused: updates wait in the stream');
        sub.resume();
        await input.close();
        await ended.future;
        expect(_transcript(updates), 'w1 w2 w3 w4');
      },
    );

    test(
      'flush before the stream is listened to fails in its future',
      () async {
        final recognizer = await create();
        addTearDown(recognizer.close);
        recognizer.transcribeStream(const Stream.empty()); // not listened
        await expectLater(recognizer.flush(), throwsStateError);
      },
    );

    test('flush after the input ended fails in its future', () async {
      final log = gatedLog(dir, 'gate');
      final recognizer = await create(config: 'gate@${log.path}');
      addTearDown(recognizer.close);
      final input = StreamController<Uint8List>();
      final stream = recognizer.transcribeStream(input.stream).toList();
      input.add(_speech([1], seconds: 5));
      await waitForLine(log, 'window');
      await input.close();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await expectLater(recognizer.flush(), throwsStateError);
      release(log);
      await stream;
    });

    test('an input error ends the stream with that error', () async {
      final recognizer = await create();
      addTearDown(recognizer.close);
      final input = StreamController<Uint8List>();
      final stream = recognizer.transcribeStream(input.stream).toList();
      input.addError(const FormatException('mic failed'));
      await expectLater(stream, throwsFormatException);
      await input.close();
    });

    test('the worker dying ends the stream with a StateError', () async {
      final recognizer = await create(config: 'dies');
      addTearDown(recognizer.close);
      final input = StreamController<Uint8List>();
      final stream = recognizer.transcribeStream(input.stream).toList();
      input.add(_speech([1], seconds: 5));
      await expectLater(stream, throwsStateError);
      await input.close();
    });
  });

  group('review fixes', () {
    int windows(File log) =>
        log.existsSync() ? '\n'.allMatches(log.readAsStringSync()).length : 0;

    test('the backlog is audio received and not inside a window that ran: '
        'an overrun comes exactly past the limit', () async {
      final log = gatedLog(dir, 'gate');
      final recognizer = await create(config: 'gate@${log.path}');
      addTearDown(recognizer.close);
      final input = StreamController<Uint8List>();
      Object? error;
      final ended = Completer<void>();
      recognizer
          .transcribeStream(input.stream)
          .listen(
            (_) {},
            onError: (Object e) => error = e,
            onDone: ended.complete,
          );
      // 5 s whose first window blocks in "native" code: all 5 s pending.
      input.add(_speech([1], seconds: 5));
      await waitForLine(log, 'window');
      // The default limit for a 5 s window is 10 s: 5 more seconds fit.
      for (var i = 0; i < 5; i++) {
        input.add(_speech([], seconds: 1));
        await Future<void>.delayed(Duration.zero);
      }
      expect(error, isNull, reason: '10 s pending is at the limit, not past');
      input.add(_speech([], seconds: 1));
      await ended.future;
      expect(error, isA<SpeechStreamOverrunException>());
      release(log);
      await input.close();
    });

    test(
      'a model that keeps up never overruns, however long the stream',
      () async {
        final recognizer = await create();
        addTearDown(recognizer.close);
        final input = StreamController<Uint8List>();
        final stream = recognizer.transcribeStream(input.stream).toList();
        // 25 s at the default 10 s limit, a second at a time.
        for (var i = 0; i < 25; i++) {
          input.add(_speech([1 + i % 9], seconds: 1));
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await input.close();
        expect(await stream, isNotEmpty);
      },
    );

    test('closing during a running flush fails it, and the stream', () async {
      final log = File('${dir.path}/gate2.log');
      addTearDown(() => release(log));
      final recognizer = await create(config: 'gate2@${log.path}');
      final input = StreamController<Uint8List>();
      final stream = recognizer.transcribeStream(input.stream).toList();
      final ended = expectLater(stream, throwsStateError);
      // 2 s: one warm-start window (the first runs after 1.25 s).
      input.add(_speech([1], seconds: 2));
      while (windows(log) < 1) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      // 0.3 s more, below the next warm start: left for the flush's own
      // window, the second, which blocks.
      input.add(_speech([], seconds: 0.3));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // The flush's own window is the second: it blocks.
      final flushed = expectLater(recognizer.flush(), throwsStateError);
      while (windows(log) < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final closing = recognizer.close();
      release(log);
      await flushed;
      await ended;
      await closing;
      await input.close();
    });

    test(
      'a flush asked for while one runs, with no audio since, shares it',
      () async {
        final log = File('${dir.path}/gate2b.log');
        addTearDown(() => release(log));
        final recognizer = await create(config: 'gate2@${log.path}');
        addTearDown(recognizer.close);
        final input = StreamController<Uint8List>();
        final updates = <TranscriptUpdate>[];
        final done = recognizer
            .transcribeStream(input.stream)
            .listen(updates.add)
            .asFuture<void>();
        // 2 s: one warm-start window; 0.3 s more for the flush's own
        // window, the second, which blocks.
        input.add(_speech([1], seconds: 2));
        while (windows(log) < 1) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        input.add(_speech([], seconds: 0.3));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final first = recognizer.flush();
        while (windows(log) < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        final second = recognizer.flush();
        release(log);
        await Future.wait([first, second]);
        expect(updates.where((u) => u.endpoint), hasLength(1));
        await input.close();
        await done;
      },
    );

    test(
      'cancelling stops at the next window: windows not started never run',
      () async {
        final log = gatedLog(dir, 'gate');
        final recognizer = await create(config: 'gate@${log.path}');
        addTearDown(recognizer.close);
        final input = StreamController<Uint8List>();
        final sub = recognizer.transcribeStream(input.stream).listen((_) {});
        // 9 s in one chunk: several windows, the first blocked.
        input.add(_speech([1, 2], seconds: 9));
        await waitForLine(log, 'window');
        final cancelling = sub.cancel();
        release(log);
        await cancelling;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(windows(log), 1);
        await input.close();
      },
    );

    test('a failed stream stops at the next window as well', () async {
      final log = gatedLog(dir, 'gate');
      final recognizer = await create(config: 'gate@${log.path}');
      addTearDown(recognizer.close);
      final input = StreamController<Uint8List>();
      final stream = recognizer.transcribeStream(input.stream).toList();
      final ended = expectLater(stream, throwsFormatException);
      input.add(_speech([1, 2], seconds: 9));
      await waitForLine(log, 'window');
      input.addError(const FormatException('mic failed'));
      await ended;
      release(log);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(windows(log), 1);
      await input.close();
    });

    test('confirmedUntil never goes back, across a flush too', () async {
      final recognizer = await create();
      addTearDown(recognizer.close);
      final input = StreamController<Uint8List>();
      final updates = <TranscriptUpdate>[];
      final done = recognizer
          .transcribeStream(
            input.stream,
            options: const TranscribeStreamOptions(
              maxBufferedAudio: Duration(minutes: 10),
            ),
          )
          .listen(updates.add)
          .asFuture<void>();
      input.add(_speech([1, 2, 3, 4, 5, 6, 7, 8]));
      await Future<void>.delayed(Duration.zero);
      await recognizer.flush();
      input.add(_speech([9, 8, 7, 6, 5, 4, 3]));
      await input.close();
      await done;
      for (var k = 1; k < updates.length; k++) {
        expect(
          updates[k].confirmedUntil >= updates[k - 1].confirmedUntil,
          isTrue,
          reason: 'update $k: ${updates[k - 1]} then ${updates[k]}',
        );
      }
    });

    test(
      'the confirmed deltas add up to the transcript, no leading space',
      () async {
        final recognizer = await create();
        addTearDown(recognizer.close);
        final updates = await recognizer
            .transcribeStream(
              _chunks(_speech([1, 2, 3]), 3200),
              options: const TranscribeStreamOptions(
                maxBufferedAudio: Duration(minutes: 10),
              ),
            )
            .toList();
        expect(updates.map((u) => u.confirmedDelta).join(), 'w1 w2 w3');
      },
    );
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
