// VoiceActivityDetector: Silero VAD on its own worker isolate, plus the
// endpoint policy of [VadOptions]. Native platforms; the web arm is
// `voice_activity_detector_stub.dart`.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:meta/meta.dart' show visibleForTesting;

import 'pcm16_framer.dart';
import 'vad_endpointer.dart';
import 'vad_event.dart';
import 'vad_options.dart';
import 'vad_worker.dart';

/// The Silero VAD model this package ships, as a Flutter asset of this
/// package: the 16 kHz model of silero-vad v6.2.3 (MIT, Silero Team),
/// exported to LiteRT by anira-project (huggingface.co/anira-project/
/// silero-vad at c302618523e14ea1a7a919df1b796096186513bb,
/// `litert/silero_vad_16k.tflite`).
const String bundledVadModelAsset =
    'packages/flutter_edge_ai_speech/assets/vad/silero_vad_16k_v6.2.3.tflite';

/// Size in bytes of [bundledVadModelAsset]; a cached copy of another size is
/// written again.
const int bundledVadModelBytes = 1254896;

/// SHA-256 of [bundledVadModelAsset], held to the file by a test.
const String bundledVadModelSha256 =
    'dfb2e98438dede7718e33cb3a63863b333b82e486ba122ebb803551094d488e9';

/// Detects speech in 16 kHz mono 16-bit little-endian PCM with Silero VAD and
/// reports where utterances start and end.
///
/// The model runs on the CPU in a worker isolate of its own, so it never
/// waits behind speech-to-text and never blocks the UI isolate. How
/// probabilities become events is [options]: see [VadOptions].
///
/// One [detect] or [probabilities] call runs at a time; each starts from a
/// fresh model state. [close] frees the model.
final class VoiceActivityDetector {
  VoiceActivityDetector._(this._worker, this.options) {
    unawaited(_worker.unexpectedExit.then((_) => _closed = true));
  }

  /// The sample rate [detect] and [probabilities] take.
  static const int sampleRate = vadSampleRate;

  /// The audio each probability covers: 512 samples, 32 ms.
  static const Duration frameDuration = Duration(milliseconds: 32);

  final VadWorker _worker;

  /// The endpoint policy of [detect].
  final VadOptions options;

  bool _busy = false;
  bool _closed = false;

  /// Loads the detector. [modelPath] is a Silero VAD `.tflite` with the
  /// bundled model's tensors (`[1,1,512]` audio and `[1,320]` state in, the
  /// probability and the state out); `null` uses the model this package
  /// ships. Throws [ArgumentError] for [options] that cannot work, and
  /// [StateError] when the model does not load.
  static Future<VoiceActivityDetector> create({
    String? modelPath,
    VadOptions options = const VadOptions(),
  }) async {
    options.validate();
    final path = modelPath ?? await _bundledModelPath();
    final worker = await VadWorker.spawn(
      modelPath: path,
      engineFactory: debugVadEngineFactory,
    );
    return VoiceActivityDetector._(worker, options);
  }

  /// Replaces the native engine in tests. Must be a top-level or static
  /// function: it crosses into the worker isolate.
  @visibleForTesting
  static VadWorkerEngineFactory? debugVadEngineFactory;

  /// Reads the bundled model in tests, instead of the Flutter asset bundle.
  @visibleForTesting
  static Future<Uint8List> Function()? debugBundledModelBytes;

  /// Where the bundled model is written for LiteRT, which opens models by
  /// path. `null` means the system temporary directory.
  @visibleForTesting
  static Directory? debugModelCacheDir;

  /// Speech events for [pcm16kMono], chunks of any size.
  ///
  /// The stream pauses its input while a chunk is in the model, so a
  /// microphone stream is never read faster than it is analysed. It ends
  /// after the input ends, with a [VadSpeechEnd] of reason
  /// [VadEndReason.inputEnded] if speech was going on; a trailing partial
  /// frame is analysed padded with zeros. Cancelling the subscription cancels
  /// the input. An error of the input, of the model, or [close] during the
  /// stream ends it with that error.
  ///
  /// Throws [StateError] if the detector is closed or another call is running.
  Stream<VadEvent> detect(Stream<Uint8List> pcm16kMono) {
    _claim('detect');
    final endpointer = VadEndpointer(options);
    final framer = Pcm16Framer(vadFrameSamples);
    final out = StreamController<VadEvent>();
    StreamSubscription<Uint8List>? input;
    var reset = true;
    var done = false;

    void finish([Object? error, StackTrace? stack]) {
      if (done) return;
      done = true;
      _busy = false;
      if (error != null) out.addError(error, stack);
      unawaited(out.close());
      unawaited(input?.cancel());
    }

    Future<void> analyse(Float32List frames) async {
      if (frames.isEmpty) return;
      final probabilities = await _worker.probabilities(frames, reset: reset);
      reset = false;
      for (final p in probabilities) {
        for (final event in endpointer.add(p)) {
          if (!done) out.add(event);
        }
      }
    }

    out
      ..onListen = () {
        input = pcm16kMono.listen(
          (chunk) {
            input!.pause();
            analyse(framer.add(chunk)).then((_) {
              if (!done) input!.resume();
            }, onError: finish);
          },
          onError: finish,
          onDone: () async {
            try {
              await analyse(framer.flushPadded());
              for (final event in endpointer.finish(
                totalSamples: framer.totalSamples,
              )) {
                if (!done) out.add(event);
              }
              finish();
            } catch (e, st) {
              finish(e, st);
            }
          },
          cancelOnError: true,
        );
      }
      ..onPause = () {
        input?.pause();
      }
      ..onResume = () {
        input?.resume();
      }
      ..onCancel = () {
        done = true;
        _busy = false;
        return input?.cancel();
      };
    return out.stream;
  }

  /// Speech probability of each 32 ms frame of [pcm16kMono], from a fresh
  /// state; a trailing partial frame is padded with zeros. For tests and for
  /// policies of an app's own.
  ///
  /// Throws [StateError] if the detector is closed or another call is running.
  Future<Float32List> probabilities(Uint8List pcm16kMono) async {
    _claim('probabilities');
    try {
      final framer = Pcm16Framer(vadFrameSamples);
      final whole = framer.add(pcm16kMono);
      final tail = framer.flushPadded();
      final frames = Float32List(whole.length + tail.length)
        ..setAll(0, whole)
        ..setAll(whole.length, tail);
      if (frames.isEmpty) return Float32List(0);
      return await _worker.probabilities(frames, reset: true);
    } finally {
      _busy = false;
    }
  }

  /// Frees the model. A [detect] stream still running ends with a
  /// [StateError]. Idempotent.
  Future<void> close() {
    _closed = true;
    return _worker.close();
  }

  void _claim(String call) {
    if (_closed || _worker.isClosed) {
      throw StateError('VoiceActivityDetector.$call: the detector is closed');
    }
    if (_busy) {
      throw StateError(
        'VoiceActivityDetector.$call: another detect or probabilities call is '
        'running; one runs at a time',
      );
    }
    _busy = true;
  }

  static Future<String> _bundledModelPath() async {
    final dir = Directory(
      '${(debugModelCacheDir ?? Directory.systemTemp).path}'
      '/flutter_edge_ai_speech',
    );
    final file = File('${dir.path}/silero_vad_16k_v6.2.3.tflite');
    if (file.existsSync() && file.lengthSync() == bundledVadModelBytes) {
      return file.path;
    }
    final bytes = await (debugBundledModelBytes ?? _assetBytes)();
    if (bytes.length != bundledVadModelBytes) {
      throw StateError(
        'VoiceActivityDetector: the bundled model $bundledVadModelAsset has '
        '${bytes.length} bytes, expected $bundledVadModelBytes',
      );
    }
    dir.createSync(recursive: true);
    // Written beside the target and renamed, so a concurrent reader never
    // opens a half-written model.
    final partial = File('${file.path}.$pid.partial');
    await partial.writeAsBytes(bytes, flush: true);
    await partial.rename(file.path);
    return file.path;
  }

  static Future<Uint8List> _assetBytes() async {
    final data = await rootBundle.load(bundledVadModelAsset);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
}
