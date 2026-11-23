// An embedding asked for on a poisoned page fails with the page's own
// LiteRtLmPagePoisonedError, not an embedding error: the caller tells the
// page's state from the embedding's. Its own file: it poisons the page lock
// of its isolate for good.
@TestOn('vm')
library;

import 'package:litertlm_dart/internal.dart';
import 'package:test/test.dart';

import 'web_embedder_fakes.dart';

void main() {
  test(
    'an embed on a poisoned page fails with LiteRtLmPagePoisonedError',
    () async {
      final embedder = fakeEmbedder(FakeWebRuntime());
      await embedder.load();
      final stuck = await liteRtLmPageLock.acquire();
      liteRtLmPageLock.poisonFor(stuck, 'A test generation never ended.');

      await expectLater(
        embedder.embed(EmbedderInput(text: 'a cat')),
        throwsA(
          isA<LiteRtLmPagePoisonedError>().having(
            (e) => e.message,
            'message',
            contains('A test generation never ended.'),
          ),
        ),
      );
    },
  );
}
