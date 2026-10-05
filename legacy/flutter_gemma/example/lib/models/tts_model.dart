import 'package:flutter_gemma/flutter_gemma.dart' show TtsModelType;

/// Catalog of on-device TTS models. SELECTABLE like STT — each entry carries
/// the [TtsModelType] that tells the generic `LiteRtTtsBackend` which
/// `TtsModelProfile` to run. Install uses one base URL + `.ofType`.
/// [matcha] and [qwen3] are wired; kokoro/supertonic are follow-ons
/// (isSupported false). [qwen3] additionally exposes 11 selectable
/// languages (`tts_screen.dart`'s language dropdown, populated from
/// `flutter_gemma_speech`'s `qwen3SupportedLanguages`) — [matcha] is
/// English-only (its locale comes from its bundle, not a runtime param).
enum TtsModel {
  matcha(
    baseUrl: 'https://huggingface.co/litert-community/Matcha-TTS/resolve/main/',
    displayName: 'Matcha-TTS',
    size: '~94MB',
    ttsModelType: TtsModelType.matcha,
    isSupported: true,
  ),
  qwen3(
    baseUrl:
        'https://huggingface.co/litert-community/Qwen3-TTS-12Hz-0.6B-Base/resolve/main/',
    displayName: 'Qwen3-TTS 0.6B (11 languages)',
    size: '~1.9GB',
    ttsModelType: TtsModelType.qwen3,
    isSupported: true,
    notes:
        'CPU only, slow (RTF≈3 — ~3s of compute per 1s of audio), needs a '
        '6 GB-RAM-class device',
  ),
  inflect(
    // The 2 tflites come from this repo; the 4 reused G2P files are fetched
    // cross-repo from Matcha (routed by
    // TtsModelType.inflect.fetchLocationFor).
    baseUrl:
        'https://huggingface.co/sasha-denisov/inflect-nano-v2-litert/resolve/main/',
    displayName: 'Inflect-Nano-v2 (fast)',
    size: '~36MB',
    ttsModelType: TtsModelType.inflect,
    isSupported: true,
    notes: 'Tiny + very fast. English only.',
  ),
  kokoro(
    baseUrl: 'https://huggingface.co/litert-community/Kokoro-82M/resolve/main/',
    displayName: 'Kokoro 82M',
    size: '~415MB',
    ttsModelType: TtsModelType.kokoro,
    isSupported: false,
    unsupportedReason:
        'Needs its own TtsModelProfile (follow-on, not shipped yet)',
  ),
  supertonic(
    baseUrl: 'https://huggingface.co/soniqo/Supertonic-3-LiteRT/resolve/main/',
    displayName: 'Supertonic-3',
    size: '~378MB',
    ttsModelType: TtsModelType.supertonic,
    isSupported: false,
    unsupportedReason:
        'Needs its own TtsModelProfile (follow-on, not shipped yet)',
  );

  const TtsModel({
    required this.baseUrl,
    required this.displayName,
    required this.size,
    required this.ttsModelType,
    this.isSupported = true,
    this.unsupportedReason,
    this.notes,
  });

  /// HuggingFace repo base URL each manifest filename is resolved against.
  final String baseUrl;

  /// Display name shown in the selection UI.
  final String displayName;

  /// Model bundle size (e.g. "~94MB"), for display only.
  final String size;

  /// Model family carried on the installed `TtsModelSpec` — selects the
  /// runtime `TtsModelProfile` in the generic `LiteRtTtsBackend`.
  final TtsModelType ttsModelType;

  /// Whether this catalog entry has a shipped `TtsModelProfile`. Entries
  /// with `isSupported: false` are listed for completeness but not wired.
  final bool isSupported;

  /// Why [isSupported] is false; null when supported.
  final String? unsupportedReason;

  /// UI-only performance/hardware caveat shown under the model info card
  /// (e.g. CPU-only, expected RTF, RAM class) — null when there's nothing
  /// notable to call out.
  final String? notes;
}
