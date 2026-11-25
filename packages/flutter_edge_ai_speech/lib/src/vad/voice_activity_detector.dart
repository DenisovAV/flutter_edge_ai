// VoiceActivityDetector: Silero VAD on its own worker isolate, plus the
// endpoint policy of [VadOptions]. Native platforms; the web arm is
// `voice_activity_detector_stub.dart`.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/services.dart' show rootBundle;
import 'package:meta/meta.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart'
    show getApplicationSupportDirectory;

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

/// Size in bytes of [bundledVadModelAsset].
const int bundledVadModelBytes = 1254896;

/// SHA-256 of [bundledVadModelAsset]. The copy LiteRT opens is checked
/// against it, and a test holds the asset to it.
const String bundledVadModelSha256 =
    'dfb2e98438dede7718e33cb3a63863b333b82e486ba122ebb803551094d488e9';

/// Detects speech in 16 kHz mono 16-bit little-endian PCM with Silero VAD and
/// reports where utterances start and end.
///
/// The model runs on the CPU in a worker isolate of its own, so it never
/// waits behind speech-to-text and never blocks the UI isolate. How
/// probabilities become events is [options]: see [VadOptions].
///
/// One [detect] stream or [probabilities] call runs at a time; each starts
/// from a fresh model state. [close] frees the model and its worker; a
/// detector that is dropped without [close] keeps them for the life of the
/// process, as every model in this package does.
final class VoiceActivityDetector {
  VoiceActivityDetector._(this._worker, this.options) {
    unawaited(_worker.unexpectedExit.then(_markClosed));
  }

  /// The sample rate [detect] and [probabilities] take.
  static const int sampleRate = vadSampleRate;

  /// The audio each probability covers: 512 samples, 32 ms.
  static const Duration frameDuration = Duration(milliseconds: 32);

  final VadWorker _worker;

  /// The endpoint policy of [detect].
  final VadOptions options;

  /// The call that holds the model, or null. A token, so a call that has
  /// ended can never release the claim of the next one.
  Object? _owner;

  bool _closed = false;
  final _closedSignal = Completer<String>();

  /// Loads the detector. [modelPath] is a Silero VAD `.tflite` with the
  /// bundled model's tensors (`[1,1,512]` audio and `[1,320]` state in, the
  /// probability and the state out); `null` uses the model this package
  /// ships, copied once into the app's support directory and checked against
  /// [bundledVadModelSha256]. Throws [ArgumentError] for [options] that cannot
  /// work, and [StateError] when the model does not load.
  static Future<VoiceActivityDetector> create({
    String? modelPath,
    VadOptions options = const VadOptions(),
  }) async {
    options.validate();
    final path = modelPath ?? await (_bundledPath ??= _writeBundledModel());
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

  /// The directory the bundled model is copied to in tests, instead of the
  /// app's support directory. Setting it forgets the path already resolved.
  @visibleForTesting
  static set debugModelCacheDir(Directory? dir) {
    _debugCacheDir = dir;
    _bundledPath = null;
  }

  static Directory? _debugCacheDir;

  /// The copy of the bundled model, written once per isolate: concurrent
  /// creates share it.
  static Future<String>? _bundledPath;

  /// Speech events for [pcm16kMono], chunks of any size.
  ///
  /// The model is claimed when the stream is listened to; if another call
  /// holds it then, or the detector is closed, the stream ends with a
  /// [StateError]. The stream pauses its input while a chunk is in the
  /// model, so a microphone stream is never read faster than it is analysed.
  /// It ends after the input ends, with a [VadSpeechEnd] of reason
  /// [VadEndReason.inputEnded] if speech was going on; a trailing partial
  /// frame is analysed padded with zeros, and no event is placed past the
  /// audio received. Cancelling the subscription cancels the input. An error
  /// of the input or of the model ends the stream with that error, and
  /// [close] (or the worker ending) ends it with a [StateError], even while
  /// the input is idle.
  Stream<VadEvent> detect(Stream<Uint8List> pcm16kMono) {
    final out = StreamController<VadEvent>();
    final token = Object();
    final endpointer = VadEndpointer(options);
    final framer = Pcm16Framer(vadFrameSamples);
    StreamSubscription<Uint8List>? input;
    var reset = true;
    var done = false;

    void release() {
      if (identical(_owner, token)) _owner = null;
    }

    void finish([Object? error, StackTrace? stack]) {
      if (done) return;
      done = true;
      release();
      if (error != null) out.addError(error, stack);
      unawaited(out.close());
      unawaited(input?.cancel());
    }

    void emit(Iterable<VadEvent> events) {
      for (final event in events) {
        if (!done) out.add(event);
      }
    }

    Future<void> analyse(Float32List frames, {int? validInLast}) async {
      if (frames.isEmpty) return;
      final probabilities = await _worker.probabilities(frames, reset: reset);
      reset = false;
      final last = probabilities.length - 1;
      for (var i = 0; i <= last; i++) {
        if (done) return;
        emit(
          endpointer.add(
            probabilities[i],
            validSamples: i == last && validInLast != null
                ? validInLast
                : vadFrameSamples,
          ),
        );
      }
    }

    out
      ..onListen = () {
        final refusal = _refusal('detect');
        if (refusal != null) {
          finish(refusal, StackTrace.current);
          return;
        }
        _owner = token;
        unawaited(
          _closedSignal.future.then((reason) => finish(StateError(reason))),
        );
        try {
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
                final pending = framer.pendingSamples;
                await analyse(framer.flushPadded(), validInLast: pending);
                emit(endpointer.finish());
                finish();
              } catch (e, st) {
                finish(e, st);
              }
            },
            cancelOnError: true,
          );
        } catch (e, st) {
          // A single-subscription input that was already listened to throws
          // here; end this stream with it instead of losing it to the zone.
          finish(e, st);
        }
      }
      ..onPause = () {
        input?.pause();
      }
      ..onResume = () {
        input?.resume();
      }
      ..onCancel = () {
        done = true;
        release();
        return input?.cancel();
      };
    return out.stream;
  }

  /// Speech probability of each 32 ms frame of [pcm16kMono], from a fresh
  /// state; a trailing partial frame is padded with zeros. For tests and for
  /// policies of an app's own.
  ///
  /// Throws [StateError] if the detector is closed or another call holds the
  /// model.
  Future<Float32List> probabilities(Uint8List pcm16kMono) async {
    final refusal = _refusal('probabilities');
    if (refusal != null) throw refusal;
    final token = Object();
    _owner = token;
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
      if (identical(_owner, token)) _owner = null;
    }
  }

  /// Frees the model and ends the worker. A [detect] stream still running
  /// ends with a [StateError]. Idempotent.
  Future<void> close() {
    _markClosed('VoiceActivityDetector was closed');
    return _worker.close();
  }

  void _markClosed(String reason) {
    _closed = true;
    if (!_closedSignal.isCompleted) _closedSignal.complete(reason);
  }

  StateError? _refusal(String call) {
    if (_closed || _worker.isClosed) {
      return StateError('VoiceActivityDetector.$call: the detector is closed');
    }
    if (_owner != null) {
      return StateError(
        'VoiceActivityDetector.$call: another detect stream or probabilities '
        'call holds the model; one runs at a time',
      );
    }
    return null;
  }

  /// Copies the bundled model to `<app support>/flutter_edge_ai_speech/vad/`
  /// unless a copy with the right SHA-256 is there already. The copy is
  /// written under a unique name and renamed into place, so two writers never
  /// share a partial file and a reader never opens one; a rename that fails
  /// because another writer got there first uses that copy once it checks.
  static Future<String> _writeBundledModel() async {
    try {
      final base = _debugCacheDir ?? await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/flutter_edge_ai_speech/vad');
      final file = File('${dir.path}/silero_vad_16k_v6.2.3.tflite');
      if (await _isBundledModel(file)) return file.path;

      final bytes = await (debugBundledModelBytes ?? _assetBytes)();
      if (sha256.convert(bytes).toString() != bundledVadModelSha256) {
        throw StateError(
          'VoiceActivityDetector: the bundled model $bundledVadModelAsset '
          '(${bytes.length} bytes) does not match its SHA-256 '
          '$bundledVadModelSha256',
        );
      }
      await dir.create(recursive: true);
      final partial = File(
        '${file.path}.$pid.${Random().nextInt(1 << 32)}.partial',
      );
      await partial.writeAsBytes(bytes, flush: true);
      try {
        await partial.rename(file.path);
      } on FileSystemException {
        // Windows refuses to replace a file another process has open.
        if (await partial.exists()) await partial.delete();
        if (!await _isBundledModel(file)) rethrow;
      }
      return file.path;
    } catch (_) {
      // Let a later create try again instead of repeating this failure.
      _bundledPath = null;
      rethrow;
    }
  }

  static Future<bool> _isBundledModel(File file) async {
    if (!await file.exists() || await file.length() != bundledVadModelBytes) {
      return false;
    }
    final digest = sha256.convert(await file.readAsBytes()).toString();
    return digest == bundledVadModelSha256;
  }

  static Future<Uint8List> _assetBytes() async {
    final data = await rootBundle.load(bundledVadModelAsset);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
}
