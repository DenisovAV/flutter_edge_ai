// Web arm of VoiceActivityDetector: the same API, refused at create. The
// detector runs LiteRT through dart:ffi, which the web does not have.
library;

import 'dart:async';
import 'dart:typed_data';

import 'vad_event.dart';
import 'vad_options.dart';

/// Detects speech in 16 kHz mono 16-bit PCM. Not available on the web:
/// [create] throws [UnsupportedError].
final class VoiceActivityDetector {
  // Never called: [create] throws first. Private, as on native platforms, so
  // an app cannot construct one here either.
  // ignore: unused_element
  VoiceActivityDetector._(this.options);

  static const int sampleRate = 16000;
  static const Duration frameDuration = Duration(milliseconds: 32);

  final VadOptions options;

  /// Throws [UnsupportedError]: the detector runs on native platforms only.
  static Future<VoiceActivityDetector> create({
    String? modelPath,
    VadOptions options = const VadOptions(),
  }) async {
    throw UnsupportedError(
      'VoiceActivityDetector is not available on the web: it runs LiteRT '
      'through dart:ffi.',
    );
  }

  Stream<VadEvent> detect(Stream<Uint8List> pcm16kMono) =>
      throw UnsupportedError('VoiceActivityDetector is not available on web');

  Future<Float32List> probabilities(Uint8List pcm16kMono) =>
      throw UnsupportedError('VoiceActivityDetector is not available on web');

  Future<void> close() async {}
}
