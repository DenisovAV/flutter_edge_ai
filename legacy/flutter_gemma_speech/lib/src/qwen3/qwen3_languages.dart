// Qwen3-TTS language-id map + the public supported-language list.
//
// Single source of truth for THREE consumers that must never drift apart:
//  - `Qwen3Prompt.build` (`qwen3_prompt.dart`), which maps a language name to
//    its control-token id for the talker prompt.
//  - `LiteRtSpeechSynthesizer.create`'s create-time language validator —
//    fails loud with an `ArgumentError` for an unknown language BEFORE
//    spawning the ~1.9 GB `TtsWorker`, rather than deep inside the worker
//    isolate on the first `synthesize` call.
//  - the example's language picker (`tts_screen.dart`), which populates its
//    dropdown from [qwen3SupportedLanguages] instead of hardcoding a second
//    copy of the list.
//
// This file is deliberately dependency-free (no imports at all, not even
// `dart:typed_data`) so it is safe to export UNCONDITIONALLY from the
// package barrel, including on platforms without `dart:io`/`dart:ffi`
// (`qwen3_prompt.dart` itself pulls in `qwen3_tables.dart`, which uses
// `dart:io` — that stays package-private).
library;

/// Language id map from the model config (`talker_config.codec_language_id`).
/// Ported from `text_to_speech_lm/python/qwen3_tts_pipeline.py LANGUAGE_IDS`.
const Map<String, int> languageIds = {
  'chinese': 2055,
  'english': 2050,
  'german': 2053,
  'italian': 2070,
  'portuguese': 2071,
  'spanish': 2054,
  'japanese': 2058,
  'korean': 2064,
  'french': 2061,
  'russian': 2069,
};

/// The full set of `language` values Qwen3-TTS accepts: [languageIds]'s
/// keys (alphabetical) plus `'auto'` (automatic language detection — no
/// language-id control token is emitted; see `Qwen3Prompt.build`'s `'auto'`
/// branch). `'auto'` is appended last since it isn't a language, it's a
/// detection mode.
final List<String> qwen3SupportedLanguages = List.unmodifiable(<String>[
  ...(languageIds.keys.toList()..sort()),
  'auto',
]);

/// Throws [ArgumentError] if [language] (case-insensitive) is not in
/// [qwen3SupportedLanguages]. Factored out as a standalone pure function
/// (rather than inlined at the call site) so it is unit-testable without
/// spawning a `TtsWorker` — which needs the ~1.9 GB Qwen3-TTS model bundle
/// on disk to construct at all.
void assertQwen3LanguageSupported(String language) {
  if (!qwen3SupportedLanguages.contains(language.toLowerCase())) {
    throw ArgumentError.value(
      language,
      'language',
      'Unsupported Qwen3-TTS language. Must be one of: '
          '${qwen3SupportedLanguages.join(', ')}',
    );
  }
}

/// Canonicalizes an already-[assertQwen3LanguageSupported]-validated
/// [language] to the lowercase form every downstream consumer expects.
///
/// `assertQwen3LanguageSupported`'s membership check is case-insensitive
/// (`language.toLowerCase()`), but `Qwen3Prompt.build`'s `'auto'` branch
/// compares case-SENSITIVELY (`language == 'auto'`; its non-`'auto'` branch
/// already lowercases via `languageIds[language.toLowerCase()]`). Without
/// normalizing once here, `'Auto'`/`'AUTO'` would pass validation at
/// `LiteRtSpeechSynthesizer.create` but then miss `Qwen3Prompt.build`'s
/// `'auto'` comparison and throw `ArgumentError` AFTER the ~1.9 GB model
/// load, at the first `synthesize` call — defeating create-time fail-fast
/// for exactly that value. Call this once, at the `create` boundary,
/// immediately after validation succeeds.
String normalizeQwen3Language(String language) => language.toLowerCase();
