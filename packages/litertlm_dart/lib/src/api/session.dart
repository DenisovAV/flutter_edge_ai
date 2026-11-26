// Kotlin's low-level Session API (Engine.createSession, Session.kt): input
// prefilled and decoded directly, without a conversation's template, history
// or tool calls. No dart:ffi, no dart:io: the same class on every platform,
// over a SessionHandle (natively the C API's session, on the web
// `@litert-lm/core`'s).

import 'dart:async';
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

  /// An encoded image (PNG, JPEG). LiteRT-LM 0.20.0 refuses it in a session
  /// ("Image must be preprocessed before being used in SessionAdvanced"), so
  /// [Session] refuses it before native with that reason.
  factory InputData.image(Uint8List bytes) = ImageInputData;

  /// Encoded audio (WAV). Refused in a session as [InputData.image] is
  /// ("Audio must be preprocessed …").
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
/// `_cancel_process`, `_clone`), run off the calling isolate. LiteRT-LM 0.20.0
/// takes text only in a session: an image or audio input is refused before
/// native with its reason ("Image must be preprocessed before being used in
/// SessionAdvanced", `session_utils.cc`); a conversation takes them. On the web
/// `@litert-lm/core` 0.20.0's `Session` takes text only too and decodes whole
/// replies: [generateContentStream] is an [UnsupportedError] there.
///
/// A session that was cancelled ([cancelProcess], or a cancelled
/// [generateContentStream] subscription) is done: LiteRT-LM neither supports
/// nor recommends reusing it (`engine.h`, `session_advanced.h`), so every
/// later call but [close] is a [StateError]. Create a new session, or clone
/// one before cancelling.
final class Session {
  Session._(this._handle, this._engineClosed);

  final SessionHandle _handle;
  final bool Function() _engineClosed;
  bool _closed = false;
  bool _cancelled = false;

  void _check() {
    if (_closed) throw StateError('The session is closed.');
    if (_engineClosed()) throw StateError('The engine is closed.');
    if (_cancelled) {
      throw StateError(
        'The session was cancelled: LiteRT-LM does not support reusing a '
        'session after cancelProcess. Create a new session.',
      );
    }
  }

  static void _checkInputs(List<InputData> inputs) {
    if (inputs.isEmpty) {
      throw ArgumentError.value(inputs, 'inputs', 'must not be empty');
    }
    for (final input in inputs) {
      final kind = switch (input) {
        TextInputData() => null,
        ImageInputData() => 'Image',
        AudioInputData() => 'Audio',
      };
      if (kind != null) {
        throw UnsupportedError(
          'LiteRT-LM 0.20.0 refuses ${kind.toLowerCase()} in a session '
          '("$kind must be preprocessed before being used in '
          'SessionAdvanced"): a session takes text only. Send media through '
          'a Conversation.',
        );
      }
    }
  }

  /// Prefills [inputs]: Kotlin's `runPrefill`. Several calls add up. Text
  /// only (see [Session]).
  Future<void> runPrefill(List<InputData> inputs) {
    _check();
    _checkInputs(inputs);
    return _handle.runPrefill(inputs);
  }

  /// Decodes the model's continuation of what was prefilled, whole:
  /// Kotlin's `runDecode`.
  Future<String> runDecode() {
    _check();
    return _handle.runDecode();
  }

  /// Prefills [inputs] and decodes the continuation: Kotlin's
  /// `generateContent`. Text only (see [Session]).
  ///
  /// A [cancelProcess] ends it normally, as it ends [generateContentStream]:
  /// it returns the text decoded until then, empty when the stop came during
  /// the prefill or before the call reached native (natively measured: Gemma
  /// 4 E2B on the CPU returned the 16 numbers it had counted, 18 ms after the
  /// stop). [runPrefill] and [runDecode] end the same way. The engine's close
  /// fails a call in flight with a [StateError].
  Future<String> generateContent(List<InputData> inputs) {
    _check();
    _checkInputs(inputs);
    return _handle.generateContent(inputs);
  }

  /// [generateContent], streamed chunk by chunk: Kotlin's
  /// `generateContentStream`. Started when listened to. A [cancelProcess],
  /// during the prefill or the decode or before either started, ends it
  /// normally with what came before; cancelling the subscription stops
  /// native too and drops the rest. Either cancel ends the session (see
  /// [Session]). The engine's close ends it with a [StateError]; reaching
  /// the engine's context window ends it with an error, as Kotlin's
  /// `onError` and the C API's final chunk say. Refused on the web.
  Stream<String> generateContentStream(List<InputData> inputs) {
    _check();
    _checkInputs(inputs);
    final source = _handle.generateContentStream(inputs);
    StreamSubscription<String>? subscription;
    var done = false;
    late final StreamController<String> out;
    out = StreamController<String>(
      onListen: () {
        subscription = source.listen(
          out.add,
          onError: out.addError,
          onDone: () {
            done = true;
            out.close();
          },
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () {
        if (!done) _cancelled = true;
        return subscription?.cancel();
      },
    );
    return out.stream;
  }

  /// Asks the prefill or decode in flight, or the next call queued behind
  /// another session's, to stop: Kotlin's `cancelProcess`. The session is
  /// done after it, whether a call ran or not: every later call but [close]
  /// is a [StateError] (see [Session]). Reaches native while the engine
  /// closes too.
  void cancelProcess() {
    if (_closed) return;
    _cancelled = true;
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
