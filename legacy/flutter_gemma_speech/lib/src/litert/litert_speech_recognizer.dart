// `SpeechRecognizer` facade over a background isolate, mirroring
// `litert_embedding_model.dart` (#299). The blocking LiteRT encode+decode
// forward passes run on a dedicated [SttWorker] isolate — spawned once,
// reused for every call — so the UI isolate stays free.
//
// The native code lives in `stt_core.dart` (driven inside the worker
// isolate); this file is the public, async, main-isolate API generic over
// [SttModelProfile] — moonshine/whisper/parakeet select a profile, not a
// recognizer subclass.

import 'dart:typed_data';

import 'package:flutter_gemma/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_gemma/core/lifecycle/close_notifier.dart';
import 'package:flutter_gemma/flutter_gemma_interface.dart'
    show SpeechRecognizer;

import '../model/stt_model_profile.dart';
import 'stt_worker.dart';

/// Signature for the `onClose` callback. Same name Flutter uses.
typedef VoidCallback = void Function();

/// Convert little-endian 16-bit PCM bytes to normalized `[-1, 1]` float32
/// samples (`/32768.0`), per the verified recipe's WAV→float32 step
/// (`docs/superpowers/notes/stt-transcript-recipe.md`).
Float32List pcm16LEToFloat32(Uint8List pcm) {
  final byteData = ByteData.sublistView(pcm);
  final sampleCount = pcm.lengthInBytes ~/ 2;
  final samples = Float32List(sampleCount);
  for (var i = 0; i < sampleCount; i++) {
    samples[i] = byteData.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return samples;
}

/// Generic LiteRT-backed [SpeechRecognizer]. Runs whichever model
/// [SttModelProfile] describes — it is NOT hardcoded to moonshine; adding a
/// new profile (+ a mel frontend for log-mel models) is enough to support a
/// new STT family without a new recognizer class.
/// Reject a [language] this model cannot use, before anything is loaded.
///
/// One home for the whole rule, called from both `LiteRtSpeechRecognizer.create`
/// (before the isolate spawns) and its `language` setter (which every retarget
/// and every direct assignment goes through). Splitting it produced the shape
/// where the create path threw and the retarget path accepted the same value,
/// then failed on every later transcription — including ones passing no
/// language at all.
///
/// `null` is always valid: it means "the model's own default".
void validateSttLanguage(String? language, {required bool supportsLanguage}) {
  if (language == null) return;
  if (!supportsLanguage) {
    throw ArgumentError.value(
      language,
      'language',
      'this model has no decoder-prompt language token; only whisper '
          'profiles accept a language',
    );
  }
  assertWhisperLanguage(language);
}

class LiteRtSpeechRecognizer extends SpeechRecognizer with CloseNotifier {
  LiteRtSpeechRecognizer._(
    this._worker,
    this.onClose,
    this._supportsLanguage,
    String? language,
  ) {
    // Through the setter, so the create path is validated by the same code as
    // every later assignment — there is no "first call is checked, the rest are
    // not" asymmetry to reason about.
    this.language = language;
  }

  final SttWorker _worker;
  final VoidCallback onClose;

  /// Whether this model's decoder prompt HAS a language slot (whisper yes,
  /// moonshine/parakeet no). Captured at create from the profile, because the
  /// profile itself lives in the worker isolate and the setter has to answer
  /// synchronously.
  final bool _supportsLanguage;

  bool _isClosed = false;

  String? _language;

  /// The default output language for [transcribe] calls that pass none.
  ///
  /// The setter is where every write is validated — the shells assign here when
  /// they retarget a cached recognizer, and an app may assign directly. Putting
  /// the check anywhere else leaves a path that accepts a language the model
  /// cannot use and then fails on every subsequent transcription, including
  /// calls that pass no language at all.
  @override
  String? get language => _language;

  @override
  set language(String? value) {
    validateSttLanguage(value, supportsLanguage: _supportsLanguage);
    _language = value;
  }

  /// Load [profile]'s model + tokenizer and prepare it for transcription on
  /// a background isolate.
  ///
  /// [modelPath] points at a `.tflite` STT model; [tokenizerPath] at its HF
  /// `tokenizer.json`. [preferredBackend] selects the LiteRT hardware
  /// accelerator (defaults to CPU).
  ///
  /// Caller owns the returned instance and must call [close] when done.
  static Future<LiteRtSpeechRecognizer> create({
    required SttModelProfile profile,
    required String modelPath,
    required String tokenizerPath,
    PreferredBackend? preferredBackend,
    VoidCallback? onClose,
    String? language,
  }) async {
    // BEFORE the spawn: the constructor's own assignment would throw only after
    // the isolate is up and the model loaded, orphaning the worker.
    validateSttLanguage(
      language,
      supportsLanguage: profile.languagePromptIndex != null,
    );
    final worker = await SttWorker.spawn(
      modelPath: modelPath,
      tokenizerPath: tokenizerPath,
      profile: profile,
      backend: preferredBackend,
    );
    // Kept as the mutable default rather than baked into the profile: the
    // caller may retarget it later without a reload (see [language]).
    return LiteRtSpeechRecognizer._(
      worker,
      onClose ?? () {},
      profile.languagePromptIndex != null,
      language,
    );
  }

  void _assertNotClosed() {
    if (_isClosed) {
      throw StateError(
        'LiteRtSpeechRecognizer is closed; create a new instance to use it',
      );
    }
  }

  @override
  Future<String> transcribe(Uint8List pcm16kMono, {String? language}) {
    _assertNotClosed();
    final samples = pcm16LEToFloat32(pcm16kMono);
    // Per-call value wins; otherwise the recognizer's current default. Both may
    // be null, which leaves the profile's own default in place.
    return _worker.transcribe(samples, language: language ?? this.language);
  }

  @override
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    try {
      await _worker.close();
    } finally {
      onClose();
      fireCloseListeners();
    }
  }
}
