import 'package:flutter_edge_ai/flutter_edge_ai.dart' show SttModelType;
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart'
    show LiteRtSpeechModels, LiteRtSttVariant;

// The model registry's builds (LiteRtSpeechModels), as functions: a variant is
// read through a getter, which is not a constant.
LiteRtSttVariant _moonshineTiny() => LiteRtSpeechModels.moonshineTiny.f32;
LiteRtSttVariant _whisperTiny() => LiteRtSpeechModels.whisperTiny.f32;
LiteRtSttVariant _parakeetCtc() => LiteRtSpeechModels.parakeetCtc0_6b.f32;
LiteRtSttVariant _moonshineTinyInt8() => LiteRtSpeechModels.moonshineTiny.i8;
LiteRtSttVariant _whisperTinyInt8() => LiteRtSpeechModels.whisperTiny.i8;
LiteRtSttVariant _whisperBaseInt8() => LiteRtSpeechModels.whisperBase.i8;

/// Catalog of on-device speech-to-text models the example can install.
///
/// Mirrors `models/embedding_model.dart` / `models/model.dart` — the STT
/// model is SELECTABLE, not hardcoded: every entry carries the
/// [SttModelType] that tells the single generic `LiteRtSttBackend`
/// (`flutter_edge_ai_speech`) which runtime `SttModelProfile` to run. Adding a
/// new family later is a new catalog entry (+ a profile + a mel frontend for
/// the log-mel families), not a new screen or a new backend/recognizer class.
///
/// [moonshineTiny] (raw PCM) and [whisperTiny] (log-mel frontend, multilingual)
/// have shipped `SttModelProfile`s. [moonshineTinyInt8], [whisperTinyInt8]
/// and [whisperBaseInt8] reuse those same profiles (zero engine code — the
/// SttModelType selects the profile, not the quantization); [isSupported]
/// on each int8 entry reflects on-device verification of int8 op-coverage
/// on the f32-proven `SttCore` path (see `stt_int8_test.dart`).
/// [parakeetCtc] runs the third family — a CTC model with its own NeMo mel
/// frontend + greedy CTC decode (device-verified, see `parakeet_ctc_test.dart`).
/// Desktop-only: 2.35 GB f32, no small/int8 export.
enum SttModel {
  moonshineTiny(
    variant: _moonshineTiny,
    displayName: 'Moonshine Tiny',
    size: '109MB',
    isSupported: true,
  ),

  whisperTiny(
    variant: _whisperTiny,
    displayName: 'Whisper Tiny',
    size: '151MB',
    isSupported: true,
  ),

  parakeetCtc(
    variant: _parakeetCtc,
    displayName: 'Parakeet CTC 0.6B (desktop)',
    size: '2.35GB',
    // Desktop-only: 2.35 GB f32 (no small/int8 export) — highest-quality of the
    // three STT families. Runs the CTC path (NeMo mel + greedy CTC decode).
    isSupported: true,
  ),

  moonshineTinyInt8(
    variant: _moonshineTinyInt8,
    displayName: 'Moonshine Tiny (int8)',
    size: '52MB',
    // Selectable, but int8 accuracy is materially lower than the f32 moonshine
    // (encoder cosine ~0.83 vs f32 on-device) — the tiny model doesn't quantize
    // cleanly. Kept enabled for comparison; expect degraded transcripts.
    isSupported: true,
  ),

  whisperTinyInt8(
    variant: _whisperTinyInt8,
    displayName: 'Whisper Tiny (int8)',
    size: '39MB',
    isSupported: true,
  ),

  whisperBaseInt8(
    variant: _whisperBaseInt8,
    displayName: 'Whisper Base (int8)',
    size: '73MB',
    isSupported: true,
  );

  final LiteRtSttVariant Function() _variant;

  /// The registry build this entry installs.
  LiteRtSttVariant get catalogVariant => _variant();

  /// STT model (`.tflite`) download URL, pinned to a commit.
  String get modelUrl => _variant().model.url;

  /// Tokenizer (`tokenizer.json`) download URL, pinned to a commit.
  String get tokenizerUrl => _variant().tokenizer.url;

  /// Display name shown in the selection UI.
  final String displayName;

  /// Model file size (e.g. "109MB"), for display only.
  final String size;

  /// Model family carried on the installed `SttModelSpec` — selects the
  /// runtime `SttModelProfile` in the generic `LiteRtSpeechRecognizer`.
  SttModelType get sttModelType => _variant().type;

  /// Whether downloading requires a HuggingFace access token.
  bool get needsAuth => _variant().model.gated || _variant().tokenizer.gated;

  /// Whether this catalog entry has a shipped `SttModelProfile`. Entries
  /// with `isSupported: false` need a log-mel frontend that hasn't landed
  /// (see [unsupportedReason]) — the selection screen must not let the user
  /// install them yet.
  final bool isSupported;

  /// Why [isSupported] is false; null when supported.
  final String? unsupportedReason;

  const SttModel({
    required LiteRtSttVariant Function() variant,
    required this.displayName,
    required this.size,
    this.isSupported = true,
    // Every catalog entry is currently supported, so no value is passed today;
    // the field is retained for `stt_models_screen`'s disabled-entry rendering
    // and for future unsupported models.
    // ignore: unused_element_parameter
    this.unsupportedReason,
  }) : _variant = variant;
}
