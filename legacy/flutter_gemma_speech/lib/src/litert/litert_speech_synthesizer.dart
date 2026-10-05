// `SpeechSynthesizer` facade over a background isolate, mirroring
// `litert_speech_recognizer.dart` (a direct STT→TTS mirror). The blocking
// LiteRT text-frontend + CFM/vocoder forward passes run on a dedicated
// [TtsWorker] isolate — spawned once, reused for every call — so the UI
// isolate stays free.
//
// The native code lives in `tts_core.dart` (driven inside the worker
// isolate) plus `tts_text_frontend.dart`; this file is the public, async,
// main-isolate API generic over [TtsModelProfile] — matcha/kokoro/supertonic
// select a profile, not a synthesizer subclass.

import 'dart:typed_data';

import 'package:flutter_gemma/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_gemma/core/lifecycle/close_notifier.dart';
import 'package:flutter_gemma/flutter_gemma_interface.dart'
    show SpeechSynthesizer;

import '../model/tts_model_profile.dart';
import '../qwen3/qwen3_languages.dart'
    show assertQwen3LanguageSupported, normalizeQwen3Language;
import 'tts_worker.dart';

/// Signature for the `onClose` callback. Same name Flutter uses.
typedef VoidCallback = void Function();

/// Generic LiteRT-backed [SpeechSynthesizer]. Runs whichever model
/// [TtsModelProfile] describes — it is NOT hardcoded to matcha; adding a new
/// profile is enough to support a new TTS family without a new synthesizer
/// class. Unlike STT, there is no input-conversion step: the worker takes
/// text in and returns 16-bit PCM bytes out.
class LiteRtSpeechSynthesizer extends SpeechSynthesizer with CloseNotifier {
  LiteRtSpeechSynthesizer._(this._worker, this.onClose);

  final TtsWorker _worker;
  final VoidCallback onClose;
  bool _isClosed = false;

  /// Load [profile]'s frontend + native model bundle and prepare it for
  /// synthesis on a background isolate.
  ///
  /// [artifactPaths] maps each of [profile]'s bundle filenames (config,
  /// dict, embedding, and the `.tflite` graphs) to their resolved on-disk
  /// paths. [preferredBackend] selects the LiteRT hardware accelerator
  /// (defaults to CPU). [language] is Qwen3-only (ignored by Matcha, which
  /// has no language parameter — its locale comes from
  /// [TtsModelProfile.locale] instead); defaults to `'english'`. For a
  /// [profile] whose [TtsModelProfile.pipeline] is
  /// [TtsPipelineKind.qwen3ArCodec], [language] is validated against
  /// `qwen3SupportedLanguages` (`qwen3_languages.dart`) and this throws
  /// [ArgumentError] for an unknown value BEFORE spawning the worker —
  /// fail-fast, ahead of the ~1.9 GB model load. Once validated,
  /// [language] is normalized to lowercase (`normalizeQwen3Language`) so the
  /// whole downstream pipeline (the worker, `Qwen3TtsCore.synthesizePcm16`,
  /// `Qwen3Prompt.build`'s case-SENSITIVE `'auto'` comparison) sees one
  /// consistent value — `'Auto'`/`'AUTO'` are accepted here exactly like
  /// `'auto'`, not just at validation time.
  ///
  /// [voice] is a forward-compat speaker x-vector override (`[1024]`,
  /// Qwen3-only): when non-null it replaces the bundle's single demo voice
  /// (`voices/demo_speaker.npy`) for every `synthesize` call on the returned
  /// instance. v1 ships exactly one voice and does not surface a voice
  /// picker anywhere — this param exists purely so a future multi-voice
  /// release doesn't need a breaking signature change.
  ///
  /// Caller owns the returned instance and must call [close] when done.
  static Future<LiteRtSpeechSynthesizer> create({
    required TtsModelProfile profile,
    required Map<String, String> artifactPaths,
    PreferredBackend? preferredBackend,
    String language = 'english',
    Float32List? voice,
    VoidCallback? onClose,
  }) async {
    var effectiveLanguage = language;
    if (profile.pipeline == TtsPipelineKind.qwen3ArCodec) {
      assertQwen3LanguageSupported(language);
      effectiveLanguage = normalizeQwen3Language(language);
    }
    final worker = await TtsWorker.spawn(
      profile: profile,
      artifactPaths: artifactPaths,
      backend: preferredBackend,
      language: effectiveLanguage,
      voice: voice,
    );
    return LiteRtSpeechSynthesizer._(worker, onClose ?? () {});
  }

  void _assertNotClosed() {
    if (_isClosed) {
      throw StateError(
        'LiteRtSpeechSynthesizer is closed; create a new instance to use it',
      );
    }
  }

  @override
  int get sampleRate => _worker.sampleRate;

  @override
  Future<Uint8List> synthesize(String text) {
    _assertNotClosed();
    return _worker.synthesize(text);
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
