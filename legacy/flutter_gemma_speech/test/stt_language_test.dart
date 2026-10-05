// The output-language path for Whisper (#500), covered at every layer that can
// silently drop it.
//
// Why this file exists, and why the assertions are shaped the way they are:
// the ORIGINAL fix for #500 threaded a `language` parameter through four
// signatures, compiled, ran, transcribed — and did nothing, because the value
// was dropped one layer below. The second attempt fixed that and still did
// nothing from the second call onward, because the recognizer singleton was
// reused on model name alone. Both bugs were invisible to `flutter analyze` and
// to the whole existing suite.
//
// So every test here is written to FAIL if the value stops arriving, not merely
// to exercise the happy path. Each one names the production line it pins.
@TestOn('vm')
library;

import 'package:flutter_gemma/core/model_management/model_specs.dart'
    show SttModelType;
import 'package:flutter_gemma_speech/src/litert/stt_core.dart'
    show promptForLanguage, resolveSttSpecialTokens;
import 'package:flutter_gemma_speech/src/litert/litert_speech_recognizer.dart'
    show validateSttLanguage;
import 'package:flutter_gemma_speech/src/model/stt_model_profile.dart';
import 'package:flutter_gemma_speech/src/tokenizer/stt_special_tokens.dart';
import 'package:flutter_test/flutter_test.dart';

/// A whisper-shaped `tokenizer.json` fragment: the four prompt specials, a few
/// language codes, and — deliberately — the task tokens whose NAMES are also
/// reachable through `<|$language|>`. `<|translate|>` is the important one: it
/// exists in the real vocabulary, so `language: 'translate'` resolves CLEANLY
/// and rewrites the prompt's task slot unless the language map excludes it.
Map<String, dynamic> _whisperTokenizerJson() => {
  'model': {
    'vocab': {'hello': 1, 'world': 2},
  },
  'added_tokens': [
    {'id': 50258, 'content': '<|startoftranscript|>'},
    {'id': 50259, 'content': '<|en|>'},
    {'id': 50261, 'content': '<|de|>'},
    {'id': 50265, 'content': '<|fr|>'},
    {'id': 50325, 'content': '<|yo|>'},
    {'id': 50322, 'content': '<|haw|>'},
    {'id': 50357, 'content': '<|nospeech|>'},
    {'id': 50358, 'content': '<|translate|>'},
    {'id': 50359, 'content': '<|transcribe|>'},
    {'id': 50363, 'content': '<|notimestamps|>'},
    {'id': 50364, 'content': '<|0.00|>'},
    {'id': 50257, 'content': '<|endoftext|>'},
    {'id': 220, 'content': 'Ġ'},
  ],
};

void main() {
  group('SttSpecialTokenResolver.languageIds', () {
    test('harvests the language codes, keyed without the delimiters', () {
      final resolver = SttSpecialTokenResolver(_whisperTokenizerJson());

      expect(resolver.languageIds['de'], 50261);
      expect(resolver.languageIds['en'], 50259);
      // Three-letter codes are real — `haw` (Hawaiian) is in whisper-tiny's
      // actual tokenizer, so the pattern must not be `[a-z]{2}`. Checked
      // against the real file: `<|yo|>` holds 50325, and `<|haw|>` is the only
      // 3-letter code in that checkpoint.
      expect(resolver.languageIds['haw'], 50322);
      expect(resolver.languageIds['yo'], 50325);
    });

    test('excludes task and control tokens reachable by the same syntax', () {
      final resolver = SttSpecialTokenResolver(_whisperTokenizerJson());

      // The whole point. `<|translate|>` IS in the vocabulary, so without the
      // shape filter `language: 'translate'` would resolve and silently swap
      // the prompt's task slot for its language slot — wrong output, no error.
      expect(resolver.languageIds.containsKey('translate'), isFalse);
      expect(resolver.languageIds.containsKey('transcribe'), isFalse);
      expect(resolver.languageIds.containsKey('notimestamps'), isFalse);
      expect(resolver.languageIds.containsKey('startoftranscript'), isFalse);
      expect(resolver.languageIds.containsKey('nospeech'), isFalse);
      expect(resolver.languageIds.containsKey('endoftext'), isFalse);
      // Timestamps carry a dot, so the letters-only pattern rejects them.
      expect(resolver.languageIds.containsKey('0.00'), isFalse);
    });
  });

  group('resolveSttSpecialTokens', () {
    test('whisper carries the language map; the default prompt is English', () {
      final resolved = resolveSttSpecialTokens(
        const SttModelProfile.whisper(),
        _whisperTokenizerJson(),
      );

      expect(resolved.decoderPromptIds, [50258, 50259, 50359, 50363]);
      expect(resolved.languageIds['de'], 50261);
    });

    test('a profile with no language slot carries no map', () {
      // Not a micro-optimization: a map here would be state nothing can read,
      // and `promptForLanguage` uses the null slot — not an empty map — to tell
      // "wrong model family" from "unknown code".
      final resolved = resolveSttSpecialTokens(
        const SttModelProfile.moonshine(),
        _whisperTokenizerJson(),
      );

      expect(resolved.languageIds, isEmpty);
      expect(const SttModelProfile.moonshine().languagePromptIndex, isNull);
    });
  });

  group('promptForLanguage', () {
    const defaultPrompt = [50258, 50259, 50359, 50363];
    const languageIds = {'en': 50259, 'de': 50261, 'fr': 50265};

    test('null returns the default prompt unchanged', () {
      expect(
        promptForLanguage(
          null,
          defaultPromptIds: defaultPrompt,
          languagePromptIndex: 1,
          languageIds: languageIds,
        ),
        defaultPrompt,
      );
    });

    test('replaces ONLY the language slot', () {
      final prompt = promptForLanguage(
        'de',
        defaultPromptIds: defaultPrompt,
        languagePromptIndex: 1,
        languageIds: languageIds,
      );

      // Pinning the whole list, not just index 1: an off-by-one that clobbered
      // `<|transcribe|>` would still put 50261 somewhere and pass a narrower
      // assertion.
      expect(prompt, [50258, 50261, 50359, 50363]);
    });

    test('does not mutate the default prompt', () {
      final original = List<int>.of(defaultPrompt);
      promptForLanguage(
        'fr',
        defaultPromptIds: original,
        languagePromptIndex: 1,
        languageIds: languageIds,
      );

      // `_decoderPromptIds` is shared across every transcription on the
      // recognizer; mutating it would make one call's language leak into the
      // next, which is the same silent-wrong-output failure one level down.
      expect(original, defaultPrompt);
    });

    test('an unknown code throws, naming the parameter — never falls back', () {
      expect(
        () => promptForLanguage(
          'xx',
          defaultPromptIds: defaultPrompt,
          languagePromptIndex: 1,
          languageIds: languageIds,
        ),
        throwsA(
          isA<ArgumentError>()
              .having((e) => e.name, 'name', 'language')
              .having((e) => e.invalidValue, 'invalidValue', 'xx'),
        ),
      );
    });

    test('a task token is rejected like any other unknown code', () {
      // Guards the resolver filter from the other side: even if `<|translate|>`
      // leaked back into the map's source, it is not a language code here.
      expect(
        () => promptForLanguage(
          'translate',
          defaultPromptIds: defaultPrompt,
          languagePromptIndex: 1,
          languageIds: languageIds,
        ),
        throwsArgumentError,
      );
    });

    test('a model with no language slot rejects rather than ignoring', () {
      // The previous version returned the moonshine profile and DISCARDED the
      // argument: `getActiveStt(language: "de")` on moonshine succeeded,
      // returned a working recognizer, and transcribed English.
      expect(
        () => promptForLanguage(
          'de',
          defaultPromptIds: const [1],
          languagePromptIndex: null,
          languageIds: const {},
        ),
        throwsArgumentError,
      );
    });
  });

  group('assertWhisperLanguage', () {
    test('accepts two- and three-letter lowercase codes', () {
      expect(assertWhisperLanguage('en'), 'en');
      expect(assertWhisperLanguage('de'), 'de');
      expect(assertWhisperLanguage('haw'), 'haw');
    });

    test('rejects the shapes a caller actually reaches for', () {
      // Each of these previously reached `<|$language|>` and died inside the
      // worker isolate with `token "<|de-DE|>" not found in tokenizer.json` —
      // a message that reads like a corrupt bundle, not a bad argument.
      for (final bad in ['', 'DE', 'de-DE', 'german', 'e', 'engl', 'de ']) {
        expect(
          () => assertWhisperLanguage(bad),
          throwsA(
            isA<ArgumentError>().having((e) => e.name, 'name', 'language'),
          ),
          reason: 'should reject ${jsonish(bad)}',
        );
      }
    });
  });

  group('SttModelProfile', () {
    test('whisper is const again and seeds English by default', () {
      // `const` matters beyond style: the profile crosses an Isolate.spawn
      // boundary, and a const instance is the file's stated design (data, not
      // subclasses). It stopped being const only while the language was baked
      // into the prompt.
      const p = SttModelProfile.whisper();
      expect(p.decoderPromptTokens[1], const SttTokenRef.name('<|en|>'));
      expect(p.languagePromptIndex, 1);
    });

    test('forType takes no language — the language is per transcription', () {
      // A compile-level guard against reintroducing the baked-in design: if
      // `forType` regains a `language` parameter, the reuse-vs-rebuild question
      // comes back with it.
      expect(
        SttModelProfile.forType(SttModelType.whisper).languagePromptIndex,
        1,
      );
      expect(
        SttModelProfile.forType(SttModelType.moonshine).languagePromptIndex,
        isNull,
      );
      expect(
        SttModelProfile.forType(SttModelType.parakeet).languagePromptIndex,
        isNull,
      );
    });
  });
  group('validateSttLanguage', () {
    // One home for the whole rule: `LiteRtSpeechRecognizer.create` calls it
    // before spawning the isolate, and its `language` setter calls it on every
    // later assignment — which is what the shells' retarget path goes through.
    // Splitting the rule is what produced "the create call throws, the retarget
    // call accepts the same value and breaks every later transcription".
    test('null is always fine — it means the model default', () {
      expect(
        () => validateSttLanguage(null, supportsLanguage: false),
        returnsNormally,
      );
    });

    test('a model with no language slot rejects any language', () {
      expect(
        () => validateSttLanguage('de', supportsLanguage: false),
        throwsA(
          isA<ArgumentError>()
              .having((e) => e.name, 'name', 'language')
              .having((e) => e.invalidValue, 'invalidValue', 'de'),
        ),
      );
    });

    test('a malformed code is rejected even where language is supported', () {
      expect(
        () => validateSttLanguage('de-DE', supportsLanguage: true),
        throwsArgumentError,
      );
      expect(
        () => validateSttLanguage('de', supportsLanguage: true),
        returnsNormally,
      );
    });
  });
}

/// Quote a value for a failure `reason` so an empty string is visible.
String jsonish(String s) => '"$s"';
