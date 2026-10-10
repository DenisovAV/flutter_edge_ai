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

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_edge_ai/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_edge_ai/core/lifecycle/close_notifier.dart';
import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart'
    show SpeechSynthesizer;
import 'package:meta/meta.dart' show visibleForTesting;

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
  LiteRtSpeechSynthesizer._(this._worker, this.onClose) {
    // A worker that dies on its own turns this synthesizer closed and tells
    // its listeners, so core drops its cached synthesizer and the next
    // `getActiveTts` builds a fresh one — instead of handing out this one,
    // whose every call would fail.
    unawaited(_worker.unexpectedExit.then(_onWorkerDied));
  }

  final TtsWorker _worker;
  final VoidCallback onClose;
  bool _isClosed = false;

  /// What every [close] after the first returns: completes, normally, once
  /// the one shared teardown is done — so a second caller waits for it
  /// instead of returning while it is still running.
  Future<void>? _closeFuture;

  /// Whether [onClose] and the close listeners have run; they run once,
  /// whether the synthesizer was closed or its worker died.
  bool _closeNotified = false;

  /// Why the worker died, when it did; later calls quote it.
  String? _deathReason;

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
  ///
  /// [engineFactory] is the worker's test seam (see [TtsWorker.spawn]);
  /// production leaves it null.
  static Future<LiteRtSpeechSynthesizer> create({
    required TtsModelProfile profile,
    required Map<String, String> artifactPaths,
    PreferredBackend? preferredBackend,
    String language = 'english',
    Float32List? voice,
    VoidCallback? onClose,
    @visibleForTesting TtsWorkerEngineFactory? engineFactory,
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
      engineFactory: engineFactory,
    );
    return LiteRtSpeechSynthesizer._(worker, onClose ?? () {});
  }

  void _assertNotClosed() {
    if (_isClosed) {
      final death = _deathReason;
      throw StateError(
        death == null
            ? 'LiteRtSpeechSynthesizer is closed; create a new instance to use '
                  'it'
            : 'LiteRtSpeechSynthesizer is closed because $death; create a new '
                  'instance to use it',
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

  /// Closes the synthesizer and its worker.
  ///
  /// Syntheses that have not started fail with a "closed" [StateError]; the
  /// one in flight finishes first, and this waits for it and for the native
  /// model to be disposed, however long that takes. A synthesizer whose
  /// worker died is already closed — its listeners have run — and this only
  /// releases what is left. Concurrent callers share one teardown.
  @override
  Future<void> close() {
    final teardownDone = _closeFuture;
    if (teardownDone != null) return teardownDone;
    final settled = Completer<void>();
    _closeFuture = settled.future;
    // `whenComplete` hands the first caller the teardown's own outcome — a
    // throwing `onClose` or listener included — while every later caller
    // gets `settled`, which only ever completes normally once it is done.
    return _close().whenComplete(settled.complete);
  }

  Future<void> _close() async {
    _isClosed = true;
    try {
      await _worker.close();
    } finally {
      _notifyClosed();
    }
  }

  void _notifyClosed() {
    if (_closeNotified) return;
    _closeNotified = true;
    try {
      onClose();
    } finally {
      // Even when `onClose` throws: core drops its cached instance on a close
      // listener, and one it never hears about is handed to every later
      // caller.
      fireCloseListeners();
    }
  }

  void _onWorkerDied(String reason) {
    _deathReason = reason;
    _isClosed = true;
    try {
      _notifyClosed();
    } catch (e, st) {
      // Nobody awaits this path, so a throwing listener would otherwise be an
      // unhandled error with no context; `print`, because edgeAiLog is silent
      // in release.
      // ignore: avoid_print
      print(
        '[flutter_edge_ai_speech] WARNING: a close listener threw while a '
        'speech synthesizer whose worker had died was being closed: $e\n$st',
      );
    }
  }
}
