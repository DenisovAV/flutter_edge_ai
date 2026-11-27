// VoiceActivityDetector: Silero VAD on its own worker isolate, plus the
// endpoint policy of [VadOptions]. Native platforms; the web arm is
// `voice_activity_detector_stub.dart`.
library;

import 'dart:async';
import 'dart:typed_data';

import 'bundled_vad_model.dart';
import 'pcm16_framer.dart';
import 'vad_endpointer.dart';
import 'vad_event.dart';
import 'vad_options.dart';
import 'vad_worker.dart';

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

  /// Ends the running detect stream when the detector closes or its worker
  /// dies; set while one runs, so nothing piles up on a long-lived detector.
  void Function(String reason)? _endDetect;

  /// Loads the detector. [modelPath] is a Silero VAD `.tflite` with the
  /// bundled model's tensors (`[1,1,512]` audio and `[1,320]` state in, the
  /// probability and the state out); `null` uses the model this package
  /// ships, copied once into the app's cache directory and checked against
  /// the SHA-256 the package pins; that needs the Flutter binding
  /// (`rootBundle`, `path_provider`), so a plain Dart program or a
  /// background isolate without it passes [modelPath].
  ///
  /// Throws [ArgumentError] for [options] that cannot work, and
  /// [StateError] when the model does not load or does not have those
  /// tensors. Copying the bundled model can also fail with the errors of
  /// the asset bundle, `path_provider` and the file system
  /// (`FlutterError`, `MissingPluginException`, `FileSystemException`).
  static Future<VoiceActivityDetector> create({
    String? modelPath,
    VadOptions options = const VadOptions(),
  }) async {
    options.validate();
    final path = modelPath ?? await bundledVadModelPath();
    final worker = await VadWorker.spawn(
      modelPath: path,
      engineFactory: debugVadEngineFactory,
    );
    return VoiceActivityDetector._(worker, options);
  }

  /// Speech events for [pcm16kMono], chunks of any size.
  ///
  /// The model is claimed when the stream is listened to; if another call
  /// holds it then, or the detector is closed, the stream ends with a
  /// [StateError]. The stream pauses its input while a chunk is in the
  /// model, so a microphone stream is never read faster than it is analysed.
  /// It ends after the input ends, with a [VadSpeechEnd] of reason
  /// [VadEndReason.inputEnded] if speech was going on; a trailing partial
  /// frame is analysed padded with zeros, and no event is placed past the
  /// audio received. A sample split across two chunks is joined; an odd
  /// byte left when the input ends (half a sample) is dropped. Cancelling the subscription cancels the input. An error
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
    // Chunks are analysed one after another, in order, even when the input
    // delivers several before listen() has returned (a sync controller
    // adding in onListen), when there is no subscription to pause yet.
    var chain = Future<void>.value();

    // Declared before use; assigned once [finish] exists.
    late final void Function(String) endDetect;

    void release() {
      if (identical(_owner, token)) _owner = null;
      if (identical(_endDetect, endDetect)) _endDetect = null;
    }

    void finish([Object? error, StackTrace? stack]) {
      if (done) return;
      done = true;
      release();
      if (error != null) out.addError(error, stack);
      unawaited(out.close());
      final cancelling = input?.cancel();
      if (cancelling != null) {
        // The stream has ended: an input that fails to stop (a recorder
        // that cannot release the microphone) has no stream to report to.
        // `print`, not edgeAiLog, so release builds see it.
        unawaited(
          cancelling.catchError((Object e) {
            // ignore: avoid_print
            print(
              '[flutter_edge_ai_speech] WARNING: cancelling the input of a '
              'VoiceActivityDetector.detect stream failed: $e',
            );
          }),
        );
      }
    }

    endDetect = (reason) => finish(StateError(reason));

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
        _endDetect = endDetect;
        try {
          input = pcm16kMono.listen(
            (chunk) {
              // Framed now, not when its turn comes: a producer may refill
              // the buffer it handed over as soon as this returns.
              final frames = framer.add(chunk);
              // Only a pause this handler made is undone below: a chunk
              // delivered inside listen() has no subscription to pause yet,
              // and resuming then would cancel a pause of the consumer's.
              final paused = input;
              paused?.pause();
              chain = chain.then((_) => done ? null : analyse(frames)).then((
                _,
              ) {
                if (!done) paused?.resume();
              }, onError: finish);
            },
            // After the chunks received before it, so an error never
            // overtakes audio already delivered.
            onError: (Object e, StackTrace st) {
              chain = chain.then((_) => finish(e, st));
            },
            onDone: () {
              chain = chain.then((_) async {
                if (done) return;
                try {
                  final pending = framer.pendingSamples;
                  await analyse(framer.flushPadded(), validInLast: pending);
                  emit(endpointer.finish());
                  finish();
                } catch (e, st) {
                  finish(e, st);
                }
              });
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
        // After the stream ended, finish() has cancelled the input and dealt
        // with its result; returning that cancel again would hand its error
        // to nobody.
        if (done) return null;
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
  /// Throws [ArgumentError] for an odd number of bytes (half a sample), and
  /// [StateError] if the detector is closed or another call holds the model.
  Future<Float32List> probabilities(Uint8List pcm16kMono) async {
    if (pcm16kMono.length.isOdd) {
      throw ArgumentError.value(
        pcm16kMono.length,
        'pcm16kMono.length',
        'must be even: 16-bit samples are two bytes',
      );
    }
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
  /// ends with a [StateError]; a [probabilities] call already sent is
  /// answered first. Completes normally even when the native dispose fails
  /// or the worker dies before it confirms: both are only printed as
  /// warnings, and the model may stay resident. Idempotent.
  Future<void> close() {
    _markClosed('VoiceActivityDetector was closed');
    return _worker.close();
  }

  void _markClosed(String reason) {
    _closed = true;
    _endDetect?.call(reason);
  }

  StateError? _refusal(String call) {
    if (_closed || _worker.isClosed) {
      final death = _worker.deathReason;
      return StateError(
        death == null
            ? 'VoiceActivityDetector.$call: the detector is closed'
            : 'VoiceActivityDetector.$call: the detector stopped: $death',
      );
    }
    if (_owner != null) {
      return StateError(
        'VoiceActivityDetector.$call: another detect stream or probabilities '
        'call holds the model; one runs at a time',
      );
    }
    return null;
  }
}
