import 'package:flutter_gemma_speech/src/tokenizer/stt_special_tokens.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final doc = {
    'model': {
      'type': 'BPE',
      'vocab': {'Hi': 0, 'Ġthere': 1, 'Ġ': 2},
    },
    'added_tokens': [
      {'id': 100, 'content': '<|endoftext|>'},
      {'id': 101, 'content': '<|startoftranscript|>'},
    ],
  };

  group('SttTokenRef', () {
    test('.id resolves to the fixed id without consulting the resolver', () {
      const ref = SttTokenRef.id(42);
      expect(
        ref.resolve(
          SttSpecialTokenResolver({
            'model': {'vocab': {}},
          }),
        ),
        42,
      );
    });

    test('.name resolves via the resolver', () {
      const ref = SttTokenRef.name('<|endoftext|>');
      expect(ref.resolve(SttSpecialTokenResolver(doc)), 100);
    });

    test('equality is value-based', () {
      expect(const SttTokenRef.id(1), const SttTokenRef.id(1));
      expect(const SttTokenRef.name('a'), const SttTokenRef.name('a'));
      expect(const SttTokenRef.id(1), isNot(const SttTokenRef.id(2)));
      expect(const SttTokenRef.id(1), isNot(const SttTokenRef.name('1')));
    });
  });

  group('SttSpecialTokenResolver', () {
    test('resolves added_tokens by content', () {
      final r = SttSpecialTokenResolver(doc);
      expect(r.resolve('<|endoftext|>'), 100);
      expect(r.resolve('<|startoftranscript|>'), 101);
    });

    test(
      'resolves plain vocab pieces by name (e.g. the GPT-2 space token)',
      () {
        final r = SttSpecialTokenResolver(doc);
        expect(r.resolve('Ġ'), 2);
        expect(r.resolve('Hi'), 0);
      },
    );

    test('missing token throws a StateError naming it', () {
      final r = SttSpecialTokenResolver(doc);
      expect(
        () => r.resolve('<|nope|>'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('<|nope|>'),
          ),
        ),
      );
    });

    test('tolerates a document with no added_tokens key', () {
      final r = SttSpecialTokenResolver({
        'model': {
          'vocab': {'a': 0},
        },
      });
      expect(r.resolve('a'), 0);
    });
  });
}
