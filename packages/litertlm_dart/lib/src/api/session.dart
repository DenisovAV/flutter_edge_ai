// Kotlin's low-level Session API (Engine.createSession, Session.kt): input
// prefilled and decoded directly, without a conversation's template, history
// or tool calls. No dart:ffi, no dart:io: the same class on every platform,
// over a SessionHandle (natively the C API's session, on the web
// `@litert-lm/core`'s).

import 'dart:typed_data';

import 'package:meta/meta.dart' show immutable;

import 'backend.dart' show SpeculativeDecodingConfig;
import 'config.dart' show LoraConfig, SamplerConfig;

/// A session's setup: Kotlin's `SessionConfig(samplerConfig, loraConfig,
/// speculativeDecodingConfig)` (Config.kt). Swift has no session API.
@immutable
final class SessionConfig {
  SessionConfig({
    this.samplerConfig,
    this.loraConfig,
    this.speculativeDecoding,
  });

  /// The sampler; null takes the model file's, field by field, then 0.8 /
  /// 40 / 0.95 / seed 1, as a conversation's does.
  final SamplerConfig? samplerConfig;

  /// The session's LoRA adapters, checked as a conversation's are. Refused
  /// on the web.
  final LoraConfig? loraConfig;

  /// Speculative decoding for this session; a field left null inherits the
  /// engine's. Refused on the web.
  final SpeculativeDecodingConfig? speculativeDecoding;
}

/// One input of a session's prefill: Kotlin's `InputData` (Session.kt).
@immutable
sealed class InputData {
  const InputData._();

  /// Text, prefilled as it is: a session applies no chat template of the
  /// conversation's kind, so the caller writes the model's turn markers.
  const factory InputData.text(String text) = TextInputData;

  /// An encoded image (PNG, JPEG), for an engine with a vision encoder.
  factory InputData.image(Uint8List bytes) = ImageInputData;

  /// Encoded audio (WAV), for an engine with an audio encoder.
  factory InputData.audio(Uint8List bytes) = AudioInputData;
}

/// [InputData.text].
final class TextInputData extends InputData {
  const TextInputData(this.text) : super._();
  final String text;
}

/// [InputData.image].
final class ImageInputData extends InputData {
  ImageInputData(Uint8List bytes)
    : bytes = Uint8List.fromList(bytes),
      super._();
  final Uint8List bytes;
}

/// [InputData.audio].
final class AudioInputData extends InputData {
  AudioInputData(Uint8List bytes)
    : bytes = Uint8List.fromList(bytes),
      super._();
  final Uint8List bytes;
}

/// What a [Session] drives: natively the C API's `LiteRtLmSession`, on the
/// web `@litert-lm/core`'s `Session`. Internal.
abstract interface class SessionHandle {
  Future<void> runPrefill(List<InputData> inputs);
  Future<String> runDecode();
  Future<String> generateContent(List<InputData> inputs);
  Stream<String> generateContentStream(List<InputData> inputs);
  void cancelProcess();
  Future<SessionHandle> clone();
  Future<void> close();
}

/// A low-level session of an engine: Kotlin's `Session` (Session.kt), made by
/// `Engine.createSession`. Input goes in with [runPrefill], the model's
/// continuation comes out of [runDecode]; [generateContent] does both. Each
/// session has its own context; calls of every session and conversation of
/// the engine run one at a time.
///
/// Natively each call is the C API's (`litert_lm_session_run_prefill`,
/// `_run_decode`, `_generate_content`, `_generate_content_stream`,
/// `_cancel_process`, `_clone`), run off the calling isolate. On the web
/// `@litert-lm/core` 0.20.0's `Session` takes text only and decodes whole
/// replies: an image or audio input and [generateContentStream] are an
/// [UnsupportedError] there.
final class Session {
  Session._(this._handle, this._engineClosed);

  final SessionHandle _handle;
  final bool Function() _engineClosed;
  bool _closed = false;

  void _check() {
    if (_closed) throw StateError('The session is closed.');
    if (_engineClosed()) throw StateError('The engine is closed.');
  }

  /// Prefills [inputs]: Kotlin's `runPrefill`. Several calls add up.
  Future<void> runPrefill(List<InputData> inputs) {
    _check();
    if (inputs.isEmpty) {
      throw ArgumentError.value(inputs, 'inputs', 'must not be empty');
    }
    return _handle.runPrefill(inputs);
  }

  /// Decodes the model's continuation of what was prefilled, whole:
  /// Kotlin's `runDecode`.
  Future<String> runDecode() {
    _check();
    return _handle.runDecode();
  }

  /// Prefills [inputs] and decodes the continuation: Kotlin's
  /// `generateContent`.
  Future<String> generateContent(List<InputData> inputs) {
    _check();
    return _handle.generateContent(inputs);
  }

  /// [generateContent], streamed chunk by chunk: Kotlin's
  /// `generateContentStream`. Started when listened to. [cancelProcess]
  /// ends it normally with what came before; cancelling the subscription
  /// stops native too and drops the rest. Refused on the web.
  Stream<String> generateContentStream(List<InputData> inputs) {
    _check();
    return _handle.generateContentStream(inputs);
  }

  /// Asks the prefill or decode in flight to stop: Kotlin's `cancelProcess`.
  /// Nothing when none runs.
  void cancelProcess() {
    if (_closed || _engineClosed()) return;
    _handle.cancelProcess();
  }

  /// A new session with this one's context and configuration, independent
  /// of it from then on: Kotlin's `Session.clone()`
  /// (`litert_lm_session_clone`; on the web `Session.clone()`).
  Future<Session> clone() async {
    _check();
    return Session._(await _handle.clone(), _engineClosed);
  }

  /// Deletes the session; a later call is a [StateError]. Its engine's close
  /// deletes it too.
  Future<void> close() {
    if (_closed) return Future.value();
    _closed = true;
    return _handle.close();
  }
}

/// A session over [handle], as an engine makes one.
Session newSession(SessionHandle handle, bool Function() engineClosed) =>
    Session._(handle, engineClosed);
