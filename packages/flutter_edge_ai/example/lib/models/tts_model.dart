import 'package:flutter_edge_ai/flutter_edge_ai.dart' show TtsModelType;
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart'
    show LiteRtSpeechModels, LiteRtTtsVariant;

// The model registry's builds (LiteRtSpeechModels), as functions: a variant is
// read through a getter, which is not a constant. Each bundle's files and
// revision come from it; Qwen3-TTS stays pinned to the revision whose root
// holds these files (its main moved them under legacy/ on 2026-10-16), and
// Inflect's four G2P files come from Matcha at the revision core pins.
LiteRtTtsVariant _matcha() => LiteRtSpeechModels.matchaTts.bundle;
LiteRtTtsVariant _qwen3() => LiteRtSpeechModels.qwen3Tts0_6b.bundle;
LiteRtTtsVariant _inflect() => LiteRtSpeechModels.inflectNanoV2.bundle;

/// Catalog of on-device TTS models. SELECTABLE like STT — each entry carries
/// the [TtsModelType] that tells the generic `LiteRtTtsBackend` which
/// `TtsModelProfile` to run. Install uses one base URL + `.ofType`.
/// [qwen3] additionally exposes 11 selectable
/// languages (`tts_screen.dart`'s language dropdown, populated from
/// `flutter_edge_ai_speech`'s `qwen3SupportedLanguages`) — [matcha] is
/// English-only (its locale comes from its bundle, not a runtime param).
enum TtsModel {
  matcha(
    variant: _matcha,
    displayName: 'Matcha-TTS',
    size: '~94MB',
    isSupported: true,
  ),
  qwen3(
    variant: _qwen3,
    displayName: 'Qwen3-TTS 0.6B (11 languages)',
    size: '~1.9GB',
    isSupported: true,
    notes:
        'CPU only, slow (RTF≈3 — ~3s of compute per 1s of audio), needs a '
        '6 GB-RAM-class device',
  ),
  inflect(
    variant: _inflect,
    displayName: 'Inflect-Nano-v2 (fast)',
    size: '~36MB',
    isSupported: true,
    notes: 'Tiny + very fast. English only.',
  );

  const TtsModel({
    required LiteRtTtsVariant Function() variant,
    required this.displayName,
    required this.size,
    this.isSupported = true,
    // Every entry is supported today; kept for the screen's disabled-entry
    // rendering.
    // ignore: unused_element_parameter
    this.unsupportedReason,
    this.notes,
  }) : _variant = variant;

  final LiteRtTtsVariant Function() _variant;

  /// The registry build this entry installs.
  LiteRtTtsVariant get catalogVariant => _variant();

  /// HuggingFace base URL, pinned to a commit, each manifest filename is
  /// resolved against.
  String get baseUrl => _variant().baseUrl;

  /// Display name shown in the selection UI.
  final String displayName;

  /// Model bundle size (e.g. "~94MB"), for display only.
  final String size;

  /// Model family carried on the installed `TtsModelSpec` — selects the
  /// runtime `TtsModelProfile` in the generic `LiteRtTtsBackend`.
  TtsModelType get ttsModelType => _variant().type;

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
