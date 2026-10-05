// The built-in HuggingFace resolver reserves the ModelFileType.builtIn slot so
// resolveHuggingFace(...) says "not possible" clearly (the OS owns the weights;
// there is no HF file) instead of core's generic "no resolver registered".

import 'package:flutter_gemma/core/model.dart' show ModelFileType;
import 'package:flutter_gemma_builtin_ai/flutter_gemma_builtin_ai.dart'
    show BuiltInAiHuggingFaceResolver;
import 'package:flutter_test/flutter_test.dart';

void main() {
  const resolver = BuiltInAiHuggingFaceResolver();

  test(
    'canResolve claims exactly ModelFileType.builtIn (never a null hint)',
    () {
      expect(
        resolver.canResolve('org/repo', fileType: ModelFileType.builtIn),
        isTrue,
      );
      // Every OTHER declared file type must NOT match; iterating
      // ModelFileType.values keeps this exhaustive if a new value is added.
      for (final t in ModelFileType.values) {
        if (t == ModelFileType.builtIn) continue;
        expect(
          resolver.canResolve('org/repo', fileType: t),
          isFalse,
          reason: '$t',
        );
      }
      expect(resolver.canResolve('org/repo'), isFalse);
    },
  );

  test('resolve throws UnsupportedError naming the repo', () {
    expect(
      () => resolver.resolve('google/gemma-nano'),
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains('google/gemma-nano'),
        ),
      ),
    );
  });

  test('name and priority are stable', () {
    expect(resolver.name, 'builtin-ai-huggingface');
    expect(resolver.priority, 0);
  });
}
