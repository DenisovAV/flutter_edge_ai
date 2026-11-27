// Web arm of VoiceActivityDetector: the same API, refused at create. The
// detector runs LiteRT through dart:ffi, which the web does not have.
library;

import 'dart:async';
import 'dart:typed_data';

import 'vad_constants.dart';
import 'vad_event.dart';
import 'vad_options.dart';

/// Detects speech in 16 kHz mono 16-bit PCM. Not available on the web:
/// [create] throws [UnsupportedError].
final class VoiceActivityDetector {
  // Never called: [create] throws first. Private, as on native platforms, so
  // an app cannot construct one here either.
  // ignore: unused_element
  VoiceActivityDetector._(this.options);

  /// The sample rate [detect] and [probabilities] take.
  static const int sampleRate = vadSampleRate;

  /// The audio each probability covers: 512 samples, 32 ms.
  static const Duration frameDuration = vadFrameDuration;

  /// The endpoint policy of [detect].
  final VadOptions options;

  /// Loads the detector on native platforms (Silero VAD on the CPU in a
  /// worker isolate of its own; the bundled model unless [modelPath] is
  /// given). On the web it throws [UnsupportedError]: the detector runs
  /// LiteRT through dart:ffi.
  static Future<VoiceActivityDetector> create({
    String? modelPath,
    VadOptions options = const VadOptions(),
  }) async {
    throw UnsupportedError(
      'VoiceActivityDetector is not available on the web: it runs LiteRT '
      'through dart:ffi.',
    );
  }

  /// Speech events for 16 kHz mono 16-bit PCM in chunks of any size: a
  /// [VadSpeechStart] when speech has lasted `VadOptions.minSpeech`, a
  /// [VadSpeechEnd] when it ends. Never reached on the web.
  Stream<VadEvent> detect(Stream<Uint8List> pcm16kMono) =>
      throw UnsupportedError('VoiceActivityDetector is not available on web');

  /// The speech probability of each 32 ms frame of [pcm16kMono]. Never
  /// reached on the web.
  Future<Float32List> probabilities(Uint8List pcm16kMono) =>
      throw UnsupportedError('VoiceActivityDetector is not available on web');

  /// Frees the model and its worker. Nothing to free on the web.
  Future<void> close() async {}
}
