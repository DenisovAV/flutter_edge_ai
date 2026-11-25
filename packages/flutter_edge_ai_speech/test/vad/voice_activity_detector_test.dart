// VoiceActivityDetector over a fake engine inside the real worker isolate: the
// stream, its input handling and its lifecycle, without a model. The native
// path is example/integration_test/vad_test.dart.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart'
    hide VoiceActivityDetector;
import 'package:flutter_edge_ai_speech/src/vad/vad_worker.dart';
// The native detector itself: the package library's conditional export
// resolves to the web stub for the analyzer, which has no test hooks.
import 'package:flutter_edge_ai_speech/src/vad/voice_activity_detector.dart';
import 'package:flutter_test/flutter_test.dart';

/// Speech when the frame's peak is above 0.1: loud frames are speech.
final class _PeakEngine implements VadWorkerEngine {
  _PeakEngine(this.modelPath);
  final String modelPath;

  @override
  void load() {
    if (modelPath.endsWith('broken.tflite')) {
      throw StateError('fake load failure');
    }
    if (modelPath.contains('flutter_edge_ai_speech') &&
        File(modelPath).lengthSync() != bundledVadModelBytes) {
      throw StateError('the bundled model was not written whole');
    }
  }

  @override
  double probability(Float32List frame) {
    var peak = 0.0;
    for (final s in frame) {
      if (s.abs() > peak) peak = s.abs();
    }
    return peak > 0.1 ? 0.9 : 0.02;
  }

  @override
  void reset() {}

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

void main() {
  setUp(() => VoiceActivityDetector.debugVadEngineFactory = _peakEngine);
  tearDown(() {
    VoiceActivityDetector.debugVadEngineFactory = null;
    VoiceActivityDetector.debugBundledModelBytes = null;
    VoiceActivityDetector.debugModelCacheDir = null;
  });

  Future<VoiceActivityDetector> create() =>
      VoiceActivityDetector.create(modelPath: '/fake/silero.tflite');

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
      expect(events, hasLength(2), reason: 'chunk size $size');
      final start = events[0] as VadSpeechStart;
      final end = events[1] as VadSpeechEnd;
      // Speech begins in the frame holding sample 8000 (frame 15, 480 ms).
      expect(start.start, const Duration(milliseconds: 450));
      expect(end.reason, VadEndReason.silence);
      expect(end.start, start.start);
      // The last loud frame is 46 (ends at 1504 ms); silence from 1504 ms.
      expect(end.end, const Duration(milliseconds: 1534));
    }
  });

  test('speech at the end of input ends with inputEnded', () async {
    final vad = await create();
    addTearDown(vad.close);
    final events = await vad
        .detect(chunked(audio(1.0, loud: true), 4000))
        .toList();
    final end = events.last as VadSpeechEnd;
    expect(end.reason, VadEndReason.inputEnded);
    expect(end.end, const Duration(seconds: 1));
  });

  test('probabilities gives one value per frame, the tail padded', () async {
    final vad = await create();
    addTearDown(vad.close);
    final p = await vad.probabilities(speech);
    expect(p, hasLength((speech.length ~/ 2 / 512).ceil()));
    expect(p.first, closeTo(0.02, 1e-6));
    expect(p[20], closeTo(0.9, 1e-6));
    expect(await vad.probabilities(Uint8List(0)), isEmpty);
  });

  test('one call at a time', () async {
    final vad = await create();
    addTearDown(vad.close);
    final input = StreamController<Uint8List>();
    final events = vad.detect(input.stream).toList();
    expect(() => vad.detect(const Stream.empty()), throwsStateError);
    expect(() => vad.probabilities(Uint8List(2)), throwsStateError);
    await input.close();
    await events;
    expect(await vad.detect(const Stream.empty()).toList(), isEmpty);
  });

  test(
    'cancelling the subscription cancels the input and frees the detector',
    () async {
      final vad = await create();
      addTearDown(vad.close);
      final cancelled = Completer<void>();
      final input = StreamController<Uint8List>(onCancel: cancelled.complete);
      final sub = vad.detect(input.stream).listen((_) {});
      input.add(audio(0.1, loud: true));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();
      await cancelled.future;
      expect(await vad.probabilities(Uint8List(1024)), hasLength(1));
    },
  );

  test('an input error ends the stream with that error', () async {
    final vad = await create();
    addTearDown(vad.close);
    final input = StreamController<Uint8List>();
    final events = vad.detect(input.stream).toList();
    input.addError(const FormatException('mic failed'));
    await expectLater(events, throwsFormatException);
    // The detector is free again.
    expect(await vad.detect(const Stream.empty()).toList(), isEmpty);
  });

  test('close during detect ends the stream with a StateError', () async {
    final vad = await create();
    final input = StreamController<Uint8List>();
    final events = vad.detect(input.stream).toList();
    input.add(audio(0.1, loud: false));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await vad.close();
    input.add(audio(0.1, loud: false));
    await expectLater(events, throwsStateError);
    expect(() => vad.detect(const Stream.empty()), throwsStateError);
    await vad.close(); // idempotent
  });

  test('a model that fails to load fails create with its message', () async {
    await expectLater(
      VoiceActivityDetector.create(modelPath: '/fake/broken.tflite'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('fake load failure'),
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
    setUp(() {
      dir = Directory.systemTemp.createTempSync('vad_cache_');
      VoiceActivityDetector.debugModelCacheDir = dir;
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test(
      'is written once to the cache directory and loaded from there',
      () async {
        var reads = 0;
        VoiceActivityDetector.debugBundledModelBytes = () async {
          reads++;
          return Uint8List(bundledVadModelBytes);
        };
        final a = await VoiceActivityDetector.create();
        await a.close();
        final b = await VoiceActivityDetector.create();
        await b.close();
        expect(reads, 1);
        final cached = File(
          '${dir.path}/flutter_edge_ai_speech/silero_vad_16k_v6.2.3.tflite',
        );
        expect(cached.lengthSync(), bundledVadModelBytes);
        expect(
          dir
              .listSync(recursive: true)
              .where((e) => e.path.endsWith('.partial')),
          isEmpty,
        );
      },
    );

    test('of the wrong size is refused', () async {
      VoiceActivityDetector.debugBundledModelBytes = () async => Uint8List(10);
      await expectLater(VoiceActivityDetector.create(), throwsStateError);
    });
  });
}
