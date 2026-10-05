// Unit coverage for `SttCore.load()`'s name->id resolution step
// (`resolveSttSpecialTokens`) -- pure, no native FFI, no file I/O. Proves:
// - moonshine resolves to byte-exact fixed values ([1]/2/null) regardless
//   of the tokenizer.json content (its refs are `SttTokenRef.id`, never
//   consulting the resolver) -- this is what keeps moonshine's decode
//   unchanged now that `load()` routes every profile through the same
//   resolution step;
// - whisper resolves its 4 default-English prompt ids + EOS + suppression by
//   NAME from a representative tokenizer.json document (added_tokens +
//   model.vocab), matching `SttSpecialTokenResolver`'s contract;
// - an unresolvable name fails loud (StateError naming it), never a silent
//   fallback id.

import 'package:flutter_gemma_speech/src/litert/stt_core.dart'
    show resolveSttSpecialTokens;
import 'package:flutter_gemma_speech/src/model/stt_model_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveSttSpecialTokens', () {
    test(
      'moonshine: resolves to [1]/2/null regardless of tokenizer content',
      () {
        const profile = SttModelProfile.moonshine();
        // Deliberately unrelated to moonshine's SentencePiece vocab --
        // proves the fixed SttTokenRef.id refs never consult the resolver.
        final resolved = resolveSttSpecialTokens(profile, {
          'model': {'vocab': <String, dynamic>{}},
        });
        expect(resolved.decoderPromptIds, [1]);
        expect(resolved.eosId, 2);
        expect(resolved.suppression, isNull);
      },
    );

    test('whisper: resolves the 4 default-English prompt ids + eos + '
        'suppression by name', () {
      final profile = SttModelProfile.whisper();
      final tokenizerJson = {
        'model': {
          'vocab': {'Ġ': 5},
        },
        'added_tokens': [
          {'id': 50258, 'content': '<|startoftranscript|>'},
          {'id': 50259, 'content': '<|en|>'},
          {'id': 50359, 'content': '<|transcribe|>'},
          {'id': 50363, 'content': '<|notimestamps|>'},
          {'id': 50257, 'content': '<|endoftext|>'},
        ],
      };
      final resolved = resolveSttSpecialTokens(profile, tokenizerJson);
      expect(resolved.decoderPromptIds, [50258, 50259, 50359, 50363]);
      expect(resolved.eosId, 50257);
      expect(resolved.suppression, isNotNull);
      expect(resolved.suppression!.suppressAboveId, 50257);
      expect(resolved.suppression!.suppressAtStepZeroIds, {5, 50257});
    });

    test('an unresolvable name throws a StateError naming it', () {
      final profile = SttModelProfile.whisper();
      expect(
        () => resolveSttSpecialTokens(profile, {
          'model': {'vocab': <String, dynamic>{}},
        }),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('<|startoftranscript|>'),
          ),
        ),
      );
    });
  });
}
