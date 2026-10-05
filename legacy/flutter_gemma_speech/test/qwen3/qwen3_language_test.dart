// Task 5.4: create-time language selection for Qwen3-TTS.
//
// `LiteRtSpeechSynthesizer.create` validates `language` against
// `qwen3SupportedLanguages` (`qwen3_languages.dart`) BEFORE spawning the
// `TtsWorker` — fail-fast, ahead of the ~1.9 GB model load — when `profile`
// is `TtsPipelineKind.qwen3ArCodec`. This file tests that validation at two
// levels:
//  - `assertQwen3LanguageSupported` directly: a pure function, no isolate/
//    artifacts needed, so it's the fast/deterministic coverage for the
//    accept/reject boundary and the language->control-token id map.
//  - `LiteRtSpeechSynthesizer.create` end to end for the reject case: proves
//    the ArgumentError actually fires from `create` itself (not just from
//    the helper in isolation), and that it does so WITHOUT touching
//    `artifactPaths` — passed empty here, which would otherwise surface as
//    a completely different (StateError/IO) failure once the worker
//    actually tried to load a bundle.
//
// The accept-case end-to-end path (`create` with a valid Qwen3 language
// actually spawning a worker and resolving the default demo x-vector) is
// NOT re-tested here — it needs the ~1.9 GB Qwen3-TTS bundle on disk and is
// already covered by the artifact-gated `test/qwen3/qwen3_worker_test.dart`
// (`@Tags(['qwen3-artifacts'])`), whose default-voice behavior Task 5.4
// leaves unchanged (`TtsWorker`'s `voice` override is opt-in and defaults to
// null, i.e. the pre-existing `readNpyF32(demoVoicePath)` path).
//
// Bundled fix (review round 1): `assertQwen3LanguageSupported`'s membership
// check is case-insensitive, but `Qwen3Prompt.build`'s `'auto'` branch
// compares case-SENSITIVELY — so `'Auto'`/`'AUTO'` used to pass validation
// at `create` but throw `ArgumentError` AFTER the ~1.9 GB model load, at the
// first `synthesize` call. `create` now normalizes via
// `normalizeQwen3Language` right after validation; the tests below cover
// both the normalizer directly and `create`'s acceptance of mixed-case
// `'auto'` (still without spawning a real worker).

import 'package:flutter_gemma_speech/src/litert/litert_speech_synthesizer.dart';
import 'package:flutter_gemma_speech/src/model/tts_model_profile.dart';
import 'package:flutter_gemma_speech/src/qwen3/qwen3_languages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('assertQwen3LanguageSupported', () {
    test('throws ArgumentError for an unknown language', () {
      expect(
        () => assertQwen3LanguageSupported('klingon'),
        throwsArgumentError,
      );
    });

    test('accepts every qwen3SupportedLanguages entry', () {
      for (final lang in qwen3SupportedLanguages) {
        expect(() => assertQwen3LanguageSupported(lang), returnsNormally);
      }
    });

    test('is case-insensitive', () {
      expect(() => assertQwen3LanguageSupported('German'), returnsNormally);
      expect(() => assertQwen3LanguageSupported('GERMAN'), returnsNormally);
    });

    test("accepts 'Auto' and 'AUTO' (case-insensitive) same as 'auto'", () {
      expect(() => assertQwen3LanguageSupported('Auto'), returnsNormally);
      expect(() => assertQwen3LanguageSupported('AUTO'), returnsNormally);
    });

    test('an unknown mixed-case language still throws ArgumentError', () {
      expect(
        () => assertQwen3LanguageSupported('Klingon'),
        throwsArgumentError,
      );
    });
  });

  group('normalizeQwen3Language', () {
    test("lowercases 'Auto'/'AUTO' to 'auto'", () {
      expect(normalizeQwen3Language('Auto'), 'auto');
      expect(normalizeQwen3Language('AUTO'), 'auto');
      expect(normalizeQwen3Language('auto'), 'auto');
    });

    test('lowercases every supported language name', () {
      for (final lang in qwen3SupportedLanguages) {
        expect(normalizeQwen3Language(lang.toUpperCase()), lang);
      }
    });
  });

  group('languageIds / qwen3SupportedLanguages (single source of truth)', () {
    test("'german' maps to control token 2053", () {
      expect(languageIds['german'], 2053);
    });

    test('qwen3SupportedLanguages contains every languageIds key plus '
        "'auto'", () {
      expect(qwen3SupportedLanguages, containsAll(languageIds.keys));
      expect(qwen3SupportedLanguages, contains('auto'));
      expect(qwen3SupportedLanguages.length, languageIds.length + 1);
    });
  });

  group('LiteRtSpeechSynthesizer.create', () {
    test('rejects an unknown qwen3 language before spawning the worker '
        '(empty artifactPaths would otherwise fail differently once the '
        'worker tried to load a bundle)', () async {
      await expectLater(
        LiteRtSpeechSynthesizer.create(
          profile: const TtsModelProfile.qwen3(),
          artifactPaths: const {},
          language: 'klingon',
        ),
        throwsArgumentError,
      );
    });

    test(
      "accepts 'Auto' and 'AUTO' the same as 'auto' — validation never "
      'rejects them as ArgumentError (they still fail later, from the '
      'empty artifactPaths, exactly like a real "auto" request would)',
      () async {
        for (final lang in ['Auto', 'AUTO', 'auto']) {
          await expectLater(
            LiteRtSpeechSynthesizer.create(
              profile: const TtsModelProfile.qwen3(),
              artifactPaths: const {},
              language: lang,
            ),
            throwsA(isNot(isA<ArgumentError>())),
            reason: "language: '$lang' must pass validation",
          );
        }
      },
    );

    test('an unknown mixed-case language still throws ArgumentError at '
        'create (not just at assertQwen3LanguageSupported)', () async {
      await expectLater(
        LiteRtSpeechSynthesizer.create(
          profile: const TtsModelProfile.qwen3(),
          artifactPaths: const {},
          language: 'Klingon',
        ),
        throwsArgumentError,
      );
    });
  });
}
