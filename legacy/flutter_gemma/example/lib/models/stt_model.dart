import 'package:flutter_gemma/flutter_gemma.dart' show SttModelType;

/// Catalog of on-device speech-to-text models the example can install.
///
/// Mirrors `models/embedding_model.dart` / `models/model.dart` — the STT
/// model is SELECTABLE, not hardcoded: every entry carries the
/// [SttModelType] that tells the single generic `LiteRtSttBackend`
/// (`flutter_gemma_speech`) which runtime `SttModelProfile` to run. Adding a
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
    modelUrl:
        'https://huggingface.co/litert-community/moonshine-tiny/resolve/main/moonshine_tiny_5s_f32.tflite',
    tokenizerUrl:
        'https://huggingface.co/UsefulSensors/moonshine/resolve/main/ctranslate2/tiny/tokenizer.json',
    displayName: 'Moonshine Tiny',
    size: '109MB',
    sttModelType: SttModelType.moonshine,
    needsAuth: false,
    isSupported: true,
  ),

  whisperTiny(
    modelUrl:
        'https://huggingface.co/litert-community/whisper-tiny/resolve/main/whisper_tiny_30s_f32.tflite',
    tokenizerUrl:
        'https://huggingface.co/openai/whisper-tiny/resolve/main/tokenizer.json',
    displayName: 'Whisper Tiny',
    size: '151MB',
    sttModelType: SttModelType.whisper,
    needsAuth: false,
    isSupported: true,
  ),

  parakeetCtc(
    modelUrl:
        'https://huggingface.co/litert-community/parakeet-ctc-0.6b/resolve/main/parakeet_ctc_0.6b_5s_f32.tflite',
    tokenizerUrl:
        'https://huggingface.co/nvidia/parakeet-ctc-0.6b/resolve/main/tokenizer.json',
    displayName: 'Parakeet CTC 0.6B (desktop)',
    size: '2.35GB',
    sttModelType: SttModelType.parakeet,
    needsAuth: false,
    // Desktop-only: 2.35 GB f32 (no small/int8 export) — highest-quality of the
    // three STT families. Runs the CTC path (NeMo mel + greedy CTC decode).
    isSupported: true,
  ),

  moonshineTinyInt8(
    modelUrl:
        'https://huggingface.co/litert-community/moonshine-tiny/resolve/main/moonshine_tiny_5s_i8.tflite',
    tokenizerUrl:
        'https://huggingface.co/UsefulSensors/moonshine/resolve/main/ctranslate2/tiny/tokenizer.json',
    displayName: 'Moonshine Tiny (int8)',
    size: '28MB',
    sttModelType: SttModelType.moonshine,
    needsAuth: false,
    // Selectable, but int8 accuracy is materially lower than the f32 moonshine
    // (encoder cosine ~0.83 vs f32 on-device) — the tiny model doesn't quantize
    // cleanly. Kept enabled for comparison; expect degraded transcripts.
    isSupported: true,
  ),

  whisperTinyInt8(
    modelUrl:
        'https://huggingface.co/litert-community/whisper-tiny/resolve/main/whisper_tiny_30s_i8.tflite',
    tokenizerUrl:
        'https://huggingface.co/openai/whisper-tiny/resolve/main/tokenizer.json',
    displayName: 'Whisper Tiny (int8)',
    size: '39MB',
    sttModelType: SttModelType.whisper,
    needsAuth: false,
    isSupported: true,
  ),

  whisperBaseInt8(
    modelUrl:
        'https://huggingface.co/litert-community/whisper-base/resolve/main/whisper_base_30s_i8.tflite',
    tokenizerUrl:
        'https://huggingface.co/openai/whisper-base/resolve/main/tokenizer.json',
    displayName: 'Whisper Base (int8)',
    size: '73MB',
    sttModelType: SttModelType.whisper,
    needsAuth: false,
    isSupported: true,
  );

  /// STT model (`.tflite`) download URL.
  final String modelUrl;

  /// Tokenizer (`tokenizer.json`) download URL.
  final String tokenizerUrl;

  /// Display name shown in the selection UI.
  final String displayName;

  /// Model file size (e.g. "109MB"), for display only.
  final String size;

  /// Model family carried on the installed `SttModelSpec` — selects the
  /// runtime `SttModelProfile` in the generic `LiteRtSpeechRecognizer`.
  final SttModelType sttModelType;

  /// Whether downloading requires a HuggingFace access token.
  final bool needsAuth;

  /// Whether this catalog entry has a shipped `SttModelProfile`. Entries
  /// with `isSupported: false` need a log-mel frontend that hasn't landed
  /// (see [unsupportedReason]) — the selection screen must not let the user
  /// install them yet.
  final bool isSupported;

  /// Why [isSupported] is false; null when supported.
  final String? unsupportedReason;

  const SttModel({
    required this.modelUrl,
    required this.tokenizerUrl,
    required this.displayName,
    required this.size,
    required this.sttModelType,
    required this.needsAuth,
    this.isSupported = true,
    // Every catalog entry is currently supported, so no value is passed today;
    // the field is retained for `stt_models_screen`'s disabled-entry rendering
    // and for future unsupported models.
    // ignore: unused_element_parameter
    this.unsupportedReason,
  });
}
