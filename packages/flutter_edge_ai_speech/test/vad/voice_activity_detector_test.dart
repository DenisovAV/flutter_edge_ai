// VoiceActivityDetector over a fake engine inside the real worker isolate: the
// stream, its input handling and its lifecycle, without a model. The native
// path is packages/flutter_edge_ai/example/integration_test/vad_test.dart.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart'
    hide VoiceActivityDetector;
import 'package:flutter_edge_ai_speech/src/vad/bundled_vad_model.dart';
import 'package:flutter_edge_ai_speech/src/vad/vad_worker.dart';
// The native detector itself: the package library's conditional export
// resolves to the web stub for the analyzer, which has no test hooks.
import 'package:flutter_edge_ai_speech/src/vad/voice_activity_detector.dart';
import 'package:flutter_test/flutter_test.dart';

import '../litert/worker_test_support.dart';

/// Speech when the frame's peak is above 0.1: loud frames are speech. A
/// silent frame's probability grows by 1e-6 per frame since the last
/// [reset], so a state that was not reset shows.
///
/// A model path `<anything>@<log>` logs `frame` per call to the log and
/// blocks on the log's gate before answering, as a native call that has not
/// returned yet; one ending in `broken.tflite` fails to load, one ending in
/// `dies.tflite` ends the worker isolate at its first frame, one ending in
/// `dies-idle.tflite` ends it 300 ms after the load, and one ending in
/// `stateful.tflite` ignores the audio and calls speech every frame from the
/// 40th since the last reset, so a stray reset shows in the events.
final class _PeakEngine implements VadWorkerEngine {
  _PeakEngine(this.modelPath);
  final String modelPath;
  int _sinceReset = 0;

  String? get _log {
    final at = modelPath.indexOf('@');
    return at < 0 ? null : modelPath.substring(at + 1);
  }

  @override
  void load() {
    if (modelPath.endsWith('broken.tflite')) {
      throw StateError('fake load failure');
    }
    if (modelPath.endsWith('dies-idle.tflite')) {
      Timer(const Duration(milliseconds: 300), Isolate.exit);
    }
  }

  @override
  double probability(Float32List frame) {
    if (modelPath.endsWith('/dies.tflite')) Isolate.exit();
    if (modelPath.endsWith('stateful.tflite')) {
      return _sinceReset++ >= 40 ? 0.9 : 0.02;
    }
    final log = _log;
    if (log != null) {
      appendLogLine(log, 'frame');
      blockUntilReleased(log);
    }
    var peak = 0.0;
    for (final s in frame) {
      if (s.abs() > peak) peak = s.abs();
    }
    final n = _sinceReset++;
    return peak > 0.1 ? 0.9 : 0.02 + (n < 1000 ? n : 1000) * 1e-6;
  }

  @override
  void reset() => _sinceReset = 0;

  @override
  void dispose() {}
}

VadWorkerEngine _peakEngine(String modelPath) => _PeakEngine(modelPath);

/// [seconds] of silence or of a loud square wave, 16 kHz PCM16 LE.
Uint8List audio(double seconds, {required bool loud}) {
  final n = (seconds * 16000).round();
  final data = ByteData(n * 2);
  for (var i = 0; i < n; i++) {
    data.setInt16(i * 2, loud ? (i.isEven ? 16000 : -16000) : 0, Endian.little);
  }
  return data.buffer.asUint8List();
}

Uint8List concat(List<Uint8List> parts) {
  final out = BytesBuilder(copy: false);
  for (final p in parts) {
    out.add(p);
  }
  return out.takeBytes();
}

/// [bytes] as a stream of chunks of [size] bytes.
Stream<Uint8List> chunked(Uint8List bytes, int size) async* {
  for (var i = 0; i < bytes.length; i += size) {
    yield Uint8List.sublistView(
      bytes,
      i,
      i + size > bytes.length ? bytes.length : i + size,
    );
  }
}

final _bundledFile = File('assets/vad/silero_vad_16k_v6.3.tflite');

void main() {
  setUp(() => debugVadEngineFactory = _peakEngine);
  tearDown(() {
    debugVadEngineFactory = null;
    debugBundledModelBytes = null;
    debugVadModelCacheDir = null;
  });

  Future<VoiceActivityDetector> create([String path = '/fake/silero.tflite']) =>
      VoiceActivityDetector.create(modelPath: path);

  final speech = concat([
    audio(0.5, loud: false),
    audio(1.0, loud: true),
    audio(1.0, loud: false),
  ]);

  test('detect reports the utterance, whatever the chunk size', () async {
    final vad = await create();
    addTearDown(vad.close);
    for (final size in [1, 333, 1024, 6000, speech.length]) {
      final events = await vad.detect(chunked(speech, size)).toList();
      // Speech begins in frame 15 (480 ms) and its last loud frame is 46;
      // silence from frame 47 (1504 ms).
      expect(events, [
        const VadSpeechStart(480 * 16 - 480),
        const VadSpeechEnd(
          480 * 16 - 480,
          1504 * 16 + 480,
          VadEndReason.silence,
        ),
      ], reason: 'chunk size $size');
    }
  });

  test('speech at the end of input ends at the last sample received', () async {
    final vad = await create();
    addTearDown(vad.close);
    // 16,100 samples: the last frame holds 228 real samples and is padded.
    final events = await vad
        .detect(chunked(audio(16100 / 16000, loud: true), 4000))
        .toList();
    expect(events.last, const VadSpeechEnd(0, 16100, VadEndReason.inputEnded));
  });

  test('probabilities gives one value per frame, the tail padded', () async {
    final vad = await create();
    addTearDown(vad.close);
    final p = await vad.probabilities(speech);
    expect(p, hasLength((speech.length ~/ 2 / 512).ceil()));
    expect(p.first, closeTo(0.02, 1e-7));
    expect(p[20], closeTo(0.9, 1e-6));
    expect(await vad.probabilities(Uint8List(0)), isEmpty);
  });

  test('every call starts from a fresh model state', () async {
    final vad = await create();
    addTearDown(vad.close);
    final silence = audio(0.5, loud: false);
    final first = await vad.probabilities(silence);
    expect(first.last, greaterThan(first.first), reason: 'the fake counts');
    expect(await vad.probabilities(silence), first);
    // A detect stream after them starts from zero as well: its first chunk
    // is analysed with the state reset.
    await vad.detect(chunked(silence, 4096)).toList();
    expect(await vad.probabilities(silence), first);
  });

  test('probabilities refuses half a sample', () async {
    final vad = await create();
    addTearDown(vad.close);
    expect(() => vad.probabilities(Uint8List(3)), throwsArgumentError);
    // ...and holds nothing after refusing.
    expect(await vad.probabilities(Uint8List(1024)), hasLength(1));
  });

  test('an input that delivers chunks inside listen() is analysed in order, '
      'as one stream', () async {
    // The fake calls speech from the 40th frame since a reset: only a
    // stream analysed as one, reset once, ever gets there.
    final vad = await create('/fake/stateful.tflite');
    addTearDown(vad.close);
    final frames = [for (var i = 0; i < 60; i++) Uint8List(1024)];
    final events = await vad.detect(_EagerStream(frames)).toList();
    expect(events.first, const VadSpeechStart(40 * 512 - 480));
  });

  test('an input error after chunks already delivered comes after their '
      'events', () async {
    final vad = await create('/fake/stateful.tflite');
    addTearDown(vad.close);
    final frames = [for (var i = 0; i < 60; i++) Uint8List(1024)];
    final events = <VadEvent>[];
    Object? error;
    final ended = Completer<void>();
    vad
        .detect(_EagerStream(frames, error: const FormatException('mic')))
        .listen(
          events.add,
          onError: (Object e) => error = e,
          onDone: ended.complete,
        );
    await ended.future;
    expect(events, [const VadSpeechStart(40 * 512 - 480)]);
    expect(error, isA<FormatException>());
  });

  test('a producer that refills the buffer it handed over does not change '
      'what was analysed', () async {
    final vad = await create();
    addTearDown(vad.close);
    final expected = await vad.detect(chunked(speech, 1024)).toList();
    expect(expected, isNotEmpty);
    // One buffer for every chunk, refilled right after each delivery, as a
    // microphone plugin with a scratch buffer may do.
    final events = await vad.detect(_ReusedBufferStream(speech, 1024)).toList();
    expect(events, expected);
  });

  test('a chunk delivered inside listen() does not undo a pause of the '
      'consumer', () async {
    final vad = await create();
    addTearDown(vad.close);
    final live = StreamController<Uint8List>();
    addTearDown(live.close);
    final sub = vad
        .detect(_EagerThenLive([audio(0.1, loud: false)], live.stream))
        .listen((_) {});
    addTearDown(sub.cancel);
    sub.pause();
    // Let the eagerly delivered chunk go through the model.
    await vad.probabilities(Uint8List(0)).catchError((_) => Float32List(0));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(live.isPaused, isTrue, reason: 'the consumer paused the stream');
  });

  test('a worker that dies while the input is idle ends the stream with '
      'StateError', () async {
    final vad = await create('/fake/dies-idle.tflite');
    addTearDown(vad.close);
    final input = StreamController<Uint8List>();
    final events = vad.detect(input.stream).toList();
    await expectLater(events, throwsStateError);
    await input.close();
  });

  test('a worker that dies ends a running stream with StateError', () async {
    final vad = await create('/fake/dies.tflite');
    addTearDown(vad.close);
    final input = StreamController<Uint8List>();
    final events = vad.detect(input.stream).toList();
    input.add(audio(0.1, loud: true));
    await expectLater(events, throwsStateError);
    expect(() => vad.probabilities(Uint8List(2)), throwsStateError);
    await input.close();
  });

  test(
    'close while a probabilities call is in the model still answers it',
    () async {
      final dir = Directory.systemTemp.createTempSync('vad_gate_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final log = gatedLog(dir, 'engine');
      final vad = await create('/fake/silero.tflite@${log.path}');
      final p = vad.probabilities(Uint8List(1024));
      await waitForLine(log, 'frame');
      final closing = vad.close();
      release(log);
      expect(await p, hasLength(1));
      await closing;
    },
  );

  group('one call at a time', () {
    test(
      'a second stream listened to while one runs ends with StateError',
      () async {
        final vad = await create();
        addTearDown(vad.close);
        final input = StreamController<Uint8List>();
        final first = vad.detect(input.stream).toList();
        await Future<void>.delayed(Duration.zero);
        await expectLater(
          vad.detect(const Stream.empty()).toList(),
          throwsStateError,
        );
        expect(() => vad.probabilities(Uint8List(2)), throwsStateError);
        await input.close();
        await first;
        expect(await vad.detect(const Stream.empty()).toList(), isEmpty);
      },
    );

    test('a stream that is never listened to holds nothing', () async {
      final vad = await create();
      addTearDown(vad.close);
      vad.detect(const Stream.empty());
      expect(await vad.probabilities(Uint8List(1024)), hasLength(1));
    });

    test(
      'a finished stream cannot release the claim of the next call',
      () async {
        final vad = await create();
        addTearDown(vad.close);
        final next = StreamController<Uint8List>();
        final nextDone = Completer<void>();
        // The next detect starts from the finished stream's last event, before
        // that stream's done is delivered (its cancel runs after).
        vad.detect(chunked(audio(0.6, loud: true), 4000)).listen((event) {
          if (event is VadSpeechEnd) {
            vad
                .detect(next.stream)
                .listen((_) {}, onDone: nextDone.complete, onError: (_) {});
          }
        });
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(
          () => vad.probabilities(Uint8List(2)),
          throwsStateError,
          reason: 'the second stream still holds the model',
        );
        await next.close();
        await nextDone.future;
      },
    );
  });

  test('cancelling during a model call cancels the input, drops the late '
      'events and frees the detector', () async {
    final dir = Directory.systemTemp.createTempSync('vad_gate_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final log = gatedLog(dir, 'engine');
    final vad = await create('/fake/silero.tflite@${log.path}');
    addTearDown(vad.close);
    final cancelled = Completer<void>();
    final input = StreamController<Uint8List>(onCancel: cancelled.complete);
    final events = <VadEvent>[];
    final sub = vad.detect(input.stream).listen(events.add);
    input.add(audio(0.5, loud: true));
    await waitForLine(log, 'frame');
    await sub.cancel();
    await cancelled.future;
    release(log);
    // The model call in flight finishes; its events go nowhere.
    final p = await vad.probabilities(Uint8List(1024));
    expect(p, hasLength(1));
    expect(events, isEmpty);
  });

  test('an input error ends the stream with that error', () async {
    final vad = await create();
    addTearDown(vad.close);
    final input = StreamController<Uint8List>();
    final events = vad.detect(input.stream).toList();
    input.addError(const FormatException('mic failed'));
    await expectLater(events, throwsFormatException);
    expect(await vad.detect(const Stream.empty()).toList(), isEmpty);
  });

  test('an input already listened to ends the stream with its error', () async {
    final vad = await create();
    addTearDown(vad.close);
    final input = StreamController<Uint8List>();
    input.stream.listen((_) {});
    await expectLater(vad.detect(input.stream).toList(), throwsStateError);
    expect(await vad.detect(const Stream.empty()).toList(), isEmpty);
    await input.close();
  });

  test('close ends a stream whose input is idle with a StateError', () async {
    final vad = await create();
    final input = StreamController<Uint8List>();
    final events = vad.detect(input.stream).toList();
    await Future<void>.delayed(Duration.zero);
    final ended = expectLater(events, throwsStateError);
    await vad.close();
    await ended;
    expect(() => vad.probabilities(Uint8List(2)), throwsStateError);
    await expectLater(
      vad.detect(const Stream.empty()).toList(),
      throwsStateError,
    );
    await vad.close(); // idempotent
    await input.close();
  });

  test('a model that fails to load fails create with its message', () async {
    await expectLater(
      create('/fake/broken.tflite'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('fake load failure'), isNot(contains('Bad state'))),
        ),
      ),
    );
  });

  test('options are checked at create', () async {
    await expectLater(
      VoiceActivityDetector.create(
        modelPath: '/fake/silero.tflite',
        options: const VadOptions(threshold: 2),
      ),
      throwsArgumentError,
    );
  });

  group('the bundled model', () {
    late Directory dir;
    late File cached;
    var reads = 0;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('vad_cache_');
      debugVadModelCacheDir = dir;
      cached = File(
        '${dir.path}/flutter_edge_ai_speech/vad/silero_vad_16k_v6.3.tflite',
      );
      reads = 0;
      debugBundledModelBytes = () async {
        reads++;
        return _bundledFile.readAsBytes();
      };
    });
    tearDown(() => dir.deleteSync(recursive: true));

    String digest(File f) => sha256.convert(f.readAsBytesSync()).toString();

    test('is copied once, even by concurrent creates', () async {
      final both = await Future.wait([
        VoiceActivityDetector.create(),
        VoiceActivityDetector.create(),
      ]);
      for (final vad in both) {
        await vad.close();
      }
      await (await VoiceActivityDetector.create()).close();
      expect(reads, 1);
      expect(digest(cached), bundledVadModelSha256);
      expect(
        dir.listSync(recursive: true).where((e) => e.path.endsWith('.partial')),
        isEmpty,
      );
    });

    test('a copy that cannot be put in place leaves no partial file and '
        'fails create with the file system error', () async {
      // A directory where the copy goes: the rename onto it fails.
      Directory(cached.path).createSync(recursive: true);
      await expectLater(
        VoiceActivityDetector.create(),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        dir.listSync(recursive: true).where((e) => e.path.endsWith('.partial')),
        isEmpty,
      );
    });

    test('a create sweeps partial copies a killed writer left, but not a '
        'fresh one another writer may still be writing', () async {
      final vadDir = Directory('${dir.path}/flutter_edge_ai_speech/vad')
        ..createSync(recursive: true);
      final stale =
          File('${vadDir.path}/silero_vad_16k_v6.3.tflite.1.2.partial')
            ..writeAsBytesSync([1, 2, 3])
            ..setLastModifiedSync(
              DateTime.now().subtract(const Duration(hours: 1)),
            );
      final fresh = File(
        '${vadDir.path}/silero_vad_16k_v6.3.tflite.3.4.partial',
      )..writeAsBytesSync([1, 2, 3]);
      await (await VoiceActivityDetector.create()).close();
      expect(stale.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
    });

    test(
      'a copy of the right size with the wrong bytes is written again',
      () async {
        cached
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(Uint8List(bundledVadModelBytes));
        await (await VoiceActivityDetector.create()).close();
        expect(reads, 1);
        expect(digest(cached), bundledVadModelSha256);
      },
    );

    test('an asset that does not match its SHA-256 is refused', () async {
      debugBundledModelBytes = () async => Uint8List(bundledVadModelBytes);
      await expectLater(VoiceActivityDetector.create(), throwsStateError);
      expect(cached.existsSync(), isFalse);
      // A later create tries again instead of repeating the failure.
      debugBundledModelBytes = () async => _bundledFile.readAsBytes();
      await (await VoiceActivityDetector.create()).close();
      expect(digest(cached), bundledVadModelSha256);
    });
  });
}

/// A stream that delivers every chunk from inside [listen], before it
/// returns the subscription, then ends: some platform streams do.
final class _EagerStream extends Stream<Uint8List> {
  _EagerStream(this._chunks, {this.error});
  final List<Uint8List> _chunks;

  /// Delivered after the chunks, instead of done.
  final Object? error;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    _chunks.forEach(onData ?? (_) {});
    final error = this.error;
    if (error != null) {
      (onError as void Function(Object, StackTrace)?)?.call(
        error,
        StackTrace.current,
      );
      return const Stream<Uint8List>.empty().listen(null);
    }
    return const Stream<Uint8List>.empty().listen(null, onDone: onDone);
  }
}

/// Delivers [bytes] in [size]-byte chunks through ONE buffer, refilled with
/// the next chunk right after each delivery, then ends.
final class _ReusedBufferStream extends Stream<Uint8List> {
  _ReusedBufferStream(this._bytes, this._size);
  final Uint8List _bytes;
  final int _size;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final out = StreamController<Uint8List>(sync: true);
    final buffer = Uint8List(_size);
    out.onListen = () async {
      // Not inside onListen: the controller would hold the first event until
      // listen() returns, after the refill.
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < _bytes.length; i += _size) {
        // A producer that respects pause: while paused the controller would
        // keep a view of the buffer this then overwrites.
        while (out.isPaused) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        final end = i + _size > _bytes.length ? _bytes.length : i + _size;
        buffer.setRange(0, end - i, _bytes, i);
        out.add(Uint8List.sublistView(buffer, 0, end - i));
        // Refill with garbage at once: whatever reads it later is wrong.
        buffer.fillRange(0, _size, 0x7f);
        await Future<void>.delayed(Duration.zero);
      }
      await out.close();
    };
    return out.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

/// Delivers [_eager] from inside [listen], before it returns, then forwards
/// [_live].
final class _EagerThenLive extends Stream<Uint8List> {
  _EagerThenLive(this._eager, this._live);
  final List<Uint8List> _eager;
  final Stream<Uint8List> _live;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    _eager.forEach(onData ?? (_) {});
    return _live.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}
